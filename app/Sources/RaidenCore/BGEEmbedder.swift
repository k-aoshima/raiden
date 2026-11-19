import CoreML
import Foundation

/// bge-m3 を Core ML で動かす。
///
/// モデルフォルダの中身（tools/convert/convert.py が作る）:
///   embed_int8.bin / embed_scale.bin  単語の埋め込み表（int8＋行ごとの尺度）。mmap して使う行だけ読む
///   body.mlmodelc                     本体（位置埋め込み〜24 層〜CLS、正規化まで）
///   vocab.bin                         XLM-RoBERTa の SentencePiece 語彙（Tokenizer.swift が mmap で読む）
///   meta.json                         {"vocab", "dim", "shapes"}
///
/// unload() でモデルと表を手放し、次の embed() で読み直す（入力欄を閉じて暫くしたら解放する設定用）。
public final class BGEEmbedder: Embedder {
    public let identifier: String
    public let dimension: Int
    public let modelDir: URL
    public let bodyURL: URL
    public let computeUnits: MLComputeUnits
    public let maxTokens: Int
    private let vocab: Int
    private let shapes: [Int]
    /// 本体が受け付ける件数（読み込んだモデルの入力の形から取る。前の版のモデルは [1]）
    public private(set) var batchSizes: [Int] = [1]
    private let lock = NSLock()

    private var tokenizer: UnigramTokenizer?
    private var model: MLModel?
    private var table: Data?   // mmap した int8 の表
    private var scales: [Float] = []
    public private(set) var lastLoadSeconds: Double = 0

    public init(modelDir: URL, body: String = "body.mlmodelc", computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
                maxTokens: Int = 128) throws {
        self.modelDir = modelDir
        self.bodyURL = modelDir.appendingPathComponent(body)
        self.computeUnits = computeUnits
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: modelDir.appendingPathComponent("meta.json"))) as? [String: Any] ?? [:]
        vocab = meta["vocab"] as? Int ?? 250002
        dimension = meta["dim"] as? Int ?? 1024
        shapes = (meta["shapes"] as? [Int] ?? [16, 32, 64, 128]).sorted()
        self.maxTokens = min(maxTokens, shapes.last ?? 128)
        identifier = "bge-m3:" + body
    }

    public var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return model != nil }

    /// 読み込み（済んでいれば何もしない）。かかった秒数を返す。
    @discardableResult
    public func load() throws -> Double {
        lock.lock(); defer { lock.unlock() }
        return try loadLocked()
    }

    private func loadLocked() throws -> Double {
        if model != nil { return 0 }
        let t0 = Date()
        if tokenizer == nil {
            tokenizer = try UnigramTokenizer(url: modelDir.appendingPathComponent("vocab.bin"))
        }
        table = try Data(contentsOf: modelDir.appendingPathComponent("embed_int8.bin"), options: .alwaysMapped)
        let sd = try Data(contentsOf: modelDir.appendingPathComponent("embed_scale.bin"))
        scales = sd.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        let m = try MLModel(contentsOf: try BGEEmbedder.compiled(bodyURL), configuration: cfg)
        model = m
        // 件数の次元: 入力の形の組（EnumeratedShapes）の先頭の数。meta.json ではなくモデルから読む（前の版のモデルと混ざっても壊れない）
        let shapes = m.modelDescription.inputDescriptionsByName["inputs_embeds"]?.multiArrayConstraint?.shapeConstraint.enumeratedShapes ?? []
        let bs = Set(shapes.compactMap { $0.first?.intValue })
        batchSizes = bs.isEmpty ? [1] : bs.sorted()
        lastLoadSeconds = Date().timeIntervalSince(t0)
        return lastLoadSeconds
    }

    /// .mlpackage なら一度だけコンパイルして ~/Library/Application Support/Raiden/compiled/ に置く
    public static func compiled(_ url: URL) throws -> URL {
        guard url.pathExtension == "mlpackage" else { return url }
        let fm = FileManager.default
        let mtime = (try? fm.attributesOfItem(atPath: url.appendingPathComponent("Manifest.json").path)[.modificationDate] as? Date)??.timeIntervalSince1970 ?? 0
        let dst = RaidenPaths.support.appendingPathComponent("compiled", isDirectory: true)
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(Int(mtime)).mlmodelc")
        if fm.fileExists(atPath: dst.path) { return dst }
        let tmp = try MLModel.compileModel(at: url)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dst)
        try fm.moveItem(at: tmp, to: dst)
        return dst
    }

    public func unload() {
        lock.lock(); defer { lock.unlock() }
        model = nil
        table = nil
        scales = []
        tokenizer = nil
    }

    public func tokenize(_ text: String) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        _ = try? loadLocked()
        return (tokenizer?.encode(text) ?? []).map(Int.init)
    }

    public func embed(_ text: String) -> [Float] {
        waitLock.lock(); waiting += 1; waitLock.unlock()
        lock.lock(); defer { lock.unlock() }
        waitLock.lock(); waiting -= 1; waitLock.unlock()
        let zero = [Float](repeating: 0, count: dimension)
        guard (try? loadLocked()) != nil, let tok = tokenizer, let model else { return zero }
        let ids = clip(tok.encode(text).map(Int.init))
        let L = shapes.first { $0 >= ids.count } ?? maxTokens
        return run(model, rows: [ids], B: 1, L: L)?.first ?? zero
    }

    // 入力 1 文（検索）を待たせない: embed を待っている人がいれば、まとめての次の組は後にする（NSLock は順番を守らないため）
    private let waitLock = NSLock()
    private var waiting = 0
    private func yieldToQueries() {
        for _ in 0..<2000 {
            waitLock.lock(); let w = waiting; waitLock.unlock()
            if w == 0 { return }
            usleep(500)
        }
    }

    /// 長すぎる入力は頭の maxTokens - 1 個と </s> にする
    private func clip(_ ids: [Int]) -> [Int] {
        ids.count > maxTokens ? Array(ids.prefix(maxTokens - 1)) + [ids.last!] : ids
    }

    /// まとめてベクトル化する（ファイルの説明文用）。モデルが件数の次元を持つとき（meta.json の batches）だけ
    /// B 件ずつ 1 回の予測に通す。短い文から順に並べてまとめるので、同じ組の中のパディングが少ない。
    /// 件数の次元が無いモデル（前の版）では 1 件ずつ embed と同じ。結果の順番は texts と同じ
    public func embedBatch(_ texts: [String], batch want: Int = 16) -> [[Float]] {
        if useBatchProvider { return embedProvider(texts, batch: want) }
        lock.lock(); _ = try? loadLocked(); let sizes = batchSizes; lock.unlock()
        let B = sizes.last { $0 <= max(want, 1) } ?? 1
        if B <= 1 || texts.count <= 1 { return texts.map { embed($0) } }
        let zero = [Float](repeating: 0, count: dimension)
        lock.lock()
        guard (try? loadLocked()) != nil, let tok = tokenizer else { lock.unlock(); return texts.map { _ in zero } }
        lock.unlock()
        let ids = texts.map { clip(tok.encode($0).map(Int.init)) }
        let order = ids.indices.sorted { ids[$0].count < ids[$1].count }
        var out = [[Float]](repeating: zero, count: texts.count)
        var i = 0
        while i < order.count {
            let chunk = Array(order[i..<min(i + B, order.count)])
            i += chunk.count
            let L = shapes.first { $0 >= ids[chunk.last!].count } ?? maxTokens
            let bShape = sizes.first { $0 >= chunk.count } ?? B
            yieldToQueries()
            lock.lock()
            let vs: [[Float]]? = (try? loadLocked()) != nil && model != nil ? run(model!, rows: chunk.map { ids[$0] }, B: bShape, L: L) : nil
            lock.unlock()
            // まとめて通せなかったら 1 件ずつ
            for (k, j) in chunk.enumerated() { out[j] = vs?[k] ?? embed(texts[j]) }
        }
        return out
    }

    /// 比べる用: 件数の次元を持たないモデルに、1 件ずつの入力を MLArrayBatchProvider でまとめて渡す
    public var useBatchProvider = false

    private func embedProvider(_ texts: [String], batch: Int) -> [[Float]] {
        let zero = [Float](repeating: 0, count: dimension)
        let dim = dimension
        var out: [[Float]] = []
        var i = 0
        while i < texts.count {
            let part = texts[i..<min(i + max(batch, 1), texts.count)]
            i += part.count
            lock.lock(); defer { lock.unlock() }
            guard (try? loadLocked()) != nil, let tok = tokenizer, let model, let table else { out += part.map { _ in zero }; continue }
            var fps: [MLFeatureProvider] = []
            for t in part {
                let ids = clip(tok.encode(t).map(Int.init))
                let L = shapes.first { $0 >= ids.count } ?? maxTokens
                guard let emb = try? MLMultiArray(shape: [1, NSNumber(value: L), NSNumber(value: dim)], dataType: .float16),
                      let mask = try? MLMultiArray(shape: [1, NSNumber(value: L)], dataType: .int32) else { continue }
                emb.withUnsafeMutableBytes { raw, _ in
                    let dst = raw.bindMemory(to: Float16.self)
                    for k in 0..<(L * dim) { dst[k] = 0 }
                    table.withUnsafeBytes { tb in
                        let src = tb.bindMemory(to: Int8.self)
                        for (t, id) in ids.enumerated() where id >= 0 && id < vocab {
                            let s = scales[id]
                            for j in 0..<dim { dst[t * dim + j] = Float16(Float(src[id * dim + j]) * s) }
                        }
                    }
                }
                mask.withUnsafeMutableBytes { raw, _ in
                    let m = raw.bindMemory(to: Int32.self)
                    for k in 0..<L { m[k] = k < ids.count ? 1 : 0 }
                }
                if let fp = try? MLDictionaryFeatureProvider(dictionary: ["inputs_embeds": MLFeatureValue(multiArray: emb),
                                                                         "attention_mask": MLFeatureValue(multiArray: mask)]) {
                    fps.append(fp)
                }
            }
            guard let res = try? model.predictions(from: MLArrayBatchProvider(array: fps), options: MLPredictionOptions()) else {
                out += part.map { _ in zero }; continue
            }
            for k in 0..<res.count {
                let arr = res.features(at: k).featureValue(for: "embedding")?.multiArrayValue
                var v = zero
                if let arr { for j in 0..<dim { v[j] = arr[j].floatValue } }
                out.append(Vec.normalized(v))
            }
        }
        return out
    }

    /// 埋め込み表から（B, L, dim）を作って本体に通す。rows が B より少なければ残りは空の行（マスクは先頭だけ 1）。lock を持って呼ぶ
    private func run(_ model: MLModel, rows: [[Int]], B: Int, L: Int) -> [[Float]]? {
        let dim = dimension
        guard let table,
              let emb = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: L), NSNumber(value: dim)], dataType: .float16),
              let mask = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: L)], dataType: .int32) else { return nil }
        emb.withUnsafeMutableBytes { raw, _ in
            let dst = raw.bindMemory(to: Float16.self)
            for i in 0..<(B * L * dim) { dst[i] = 0 }
            table.withUnsafeBytes { tb in
                let src = tb.bindMemory(to: Int8.self)
                for (r, ids) in rows.enumerated() {
                    for (t, id) in ids.enumerated() where id >= 0 && id < vocab && t < L {
                        let s = scales[id]
                        let o = id * dim, d = (r * L + t) * dim
                        for j in 0..<dim { dst[d + j] = Float16(Float(src[o + j]) * s) }
                    }
                }
            }
        }
        mask.withUnsafeMutableBytes { raw, _ in
            let m = raw.bindMemory(to: Int32.self)
            for r in 0..<B {
                let n = r < rows.count ? rows[r].count : 1
                for i in 0..<L { m[r * L + i] = i < n ? 1 : 0 }
            }
        }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [
                "inputs_embeds": MLFeatureValue(multiArray: emb),
                "attention_mask": MLFeatureValue(multiArray: mask)]),
              let out = try? model.prediction(from: input),
              let arr = out.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        let stride = arr.shape.count >= 2 ? arr.strides[0].intValue : dim
        var vs: [[Float]] = []
        for r in 0..<rows.count {
            var v = [Float](repeating: 0, count: dim)
            if arr.dataType == .float32 {
                arr.withUnsafeBytes { raw in
                    let p = raw.bindMemory(to: Float.self)
                    for i in 0..<dim { v[i] = p[r * stride + i] }
                }
            } else {
                for i in 0..<dim { v[i] = arr[r * stride + i].floatValue }
            }
            vs.append(Vec.normalized(v))
        }
        return vs
    }
}
