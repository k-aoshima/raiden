import CoreML
import Foundation

/// bge-m3 を Core ML で動かす。
///
/// モデルフォルダの中身（tools/convert/convert.py が作る）:
///   embed_int8.bin / embed_scale.bin  単語の埋め込み表（int8＋行ごとの尺度）。mmap して使う行だけ読む
///   body.mlmodelc                     本体（位置埋め込み〜24 層〜CLS、正規化まで）
///   vocab.bin                         XLM-RoBERTa の SentencePiece 語彙（Tokenizer.swift が mmap で読む）
///   meta.json                         {"vocab", "dim", "shapes"}。ANE 版は "functions"（["b1_s32", …]）と "units": "ane" も
///
/// ANE 版の本体（tools/convert/convert_ane.py）は形が固定の関数を 1 つのモデルにまとめたもの（multifunction）。
/// 関数ごとに MLModel を読み（MLModelConfiguration.functionName）、件数 B と長さ L で選ぶ。マスクは fp16。
/// computeUnits を渡さなければ meta.json の "units" に従う（"ane" なら .cpuAndNeuralEngine、無ければ .cpuOnly）。
///
/// unload() でモデルと表を手放し、次の embed() で読み直す（入力欄を閉じて暫くしたら解放する設定用）。
public final class BGEEmbedder: UrgentEmbedder {
    public let identifier: String
    public let dimension: Int
    public let modelDir: URL
    public let bodyURL: URL
    /// 実際に使っている装置。ANE で読めなかったときは .cpuOnly に変わる
    public private(set) var computeUnits: MLComputeUnits
    public let maxTokens: Int
    private let vocab: Int
    private let shapes: [Int]
    /// ANE 版の関数名（"b{B}_s{S}"）。空なら前の形（1 つのモデルで EnumeratedShapes）
    private let functions: [String]
    private var fnModels: [String: MLModel] = [:]
    /// ANE で読み終えた関数（裏で 1 つずつ読む。読み終わるまでの代わりは modelFor）
    private var aneLoaded: Set<String> = []
    private var aneGeneration = 0
    private var aneFailed = false
    /// 本体が受け付ける件数（読み込んだモデルの入力の形から取る。前の版のモデルは [1]）
    public private(set) var batchSizes: [Int] = [1]
    private let lock = NSLock()

    private var tokenizer: UnigramTokenizer?
    private var model: MLModel?
    private var table: Data?   // mmap した int8 の表
    private var scales: [Float] = []
    public private(set) var lastLoadSeconds: Double = 0

    public init(modelDir: URL, body: String = "body.mlmodelc", computeUnits: MLComputeUnits? = nil,
                maxTokens: Int = 128) throws {
        self.modelDir = modelDir
        self.bodyURL = modelDir.appendingPathComponent(body)
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: modelDir.appendingPathComponent("meta.json"))) as? [String: Any] ?? [:]
        self.computeUnits = computeUnits ?? ((meta["units"] as? String) == "ane" ? .cpuAndNeuralEngine : .cpuOnly)
        functions = meta["functions"] as? [String] ?? []
        vocab = meta["vocab"] as? Int ?? 250002
        dimension = meta["dim"] as? Int ?? 1024
        shapes = (meta["shapes"] as? [Int] ?? [16, 32, 64, 128]).sorted()
        self.maxTokens = min(maxTokens, shapes.last ?? 128)
        // ANE 版は数字が CPU 版と少し違う（cos の差 0.00x）ので、保存済みのベクトルを作り直すよう名前を変える。
        // 同じ名前（body.mlmodelc）で中身が変わっても作り直すよう、model.mil の印を付ける
        identifier = "bge-m3:" + body + (functions.isEmpty ? "" : ":ane-" + (BGEEmbedder.milHash(bodyURL).map { String($0, radix: 16) } ?? "pkg"))
        // ファイル・フォルダの 2 値のベクトルの中心（無ければ中心を引かない）
        BinVec.loadCenter(modelDir.appendingPathComponent("center.bin"))
    }

    public var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    /// 読み込み済みか（ANE 版は関数ごとに後から読むので fnReady）
    private var ready: Bool { model != nil || fnReady }
    private var fnReady = false

    /// 読み込み（済んでいれば何もしない）。かかった秒数を返す。
    @discardableResult
    public func load() throws -> Double {
        lock.lock(); defer { lock.unlock() }
        return try loadLocked()
    }

    private func loadLocked() throws -> Double {
        if ready { return 0 }
        let t0 = Date()
        if tokenizer == nil {
            tokenizer = try UnigramTokenizer(url: modelDir.appendingPathComponent("vocab.bin"))
        }
        table = try Data(contentsOf: modelDir.appendingPathComponent("embed_int8.bin"), options: .alwaysMapped)
        let sd = try Data(contentsOf: modelDir.appendingPathComponent("embed_scale.bin"))
        scales = sd.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        if !functions.isEmpty {
            // ANE 版: 関数（形）ごとに MLModel を読む。件数は関数名から。
            // ANE 向けのコンパイルは初回だけ 1 関数 17 秒〜3 分（件数 8・長さ 128 が最長）かかり、OS（aned）が
            // キャッシュする（2 回目からは 1 関数 0.5 秒）。キャッシュはモデルの場所ごとなので、アプリを入れ替えても変わらない場所（stableCopy）から読む。待たせないよう ANE は裏で 1 つずつ読む。
            // 読み終わる前の入力 1 文は代わりの 1 関数で通し（modelFor）、まとめての組は 1 件ずつに回す
            let url = try BGEEmbedder.stableCopy(try BGEEmbedder.compiled(bodyURL))
            fnURL = url
            fnModels = [:]
            fnReady = true
            let bs = Set(functions.compactMap { f in f.split(separator: "_").first.flatMap { Int($0.dropFirst()) } })
            batchSizes = bs.isEmpty ? [1] : bs.sorted()
            if computeUnits != .cpuOnly && !aneFailed { startANELoad(url) }
            lastLoadSeconds = Date().timeIntervalSince(t0)
            return lastLoadSeconds
        }
        let url = try BGEEmbedder.compiled(bodyURL)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        let m = try MLModel(contentsOf: url, configuration: cfg)
        model = m
        // 件数の次元: 入力の形の組（EnumeratedShapes）の先頭の数。meta.json ではなくモデルから読む（前の版のモデルと混ざっても壊れない）
        let shapes = m.modelDescription.inputDescriptionsByName["inputs_embeds"]?.multiArrayConstraint?.shapeConstraint.enumeratedShapes ?? []
        let bs = Set(shapes.compactMap { $0.first?.intValue })
        batchSizes = bs.isEmpty ? [1] : bs.sorted()
        lastLoadSeconds = Date().timeIntervalSince(t0)
        return lastLoadSeconds
    }

    private var fnURL: URL?

    /// 裏で ANE 用に関数を 1 つずつ読み、読めたものから差し替える。unload で打ち切る
    private func startANELoad(_ url: URL) {
        aneGeneration += 1
        let gen = aneGeneration
        // 件数 1 のいちばん長い関数を先に（読み終わる前の入力 1 文の代わりに使う。modelFor）、次に件数 1、最後にまとめて用
        let b1 = functions.filter { $0.hasPrefix("b1_") }
        let order = Array(b1.suffix(1)) + b1.dropLast() + functions.filter { !$0.hasPrefix("b1_") }
        let units = computeUnits
        // 動作の記録はアプリのときだけ（答え合わせから本物のログに書かない）
        let log = Bundle.main.bundleURL.pathExtension == "app"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let t0 = Date()
            defer {
                if log, let self {
                    let p = self.aneProgress
                    rlog(String(format: "ANE の読み込み %d/%d 関数 %.1fs", p.loaded, p.total, Date().timeIntervalSince(t0)))
                }
            }
            for f in order {
                let cfg = MLModelConfiguration()
                cfg.computeUnits = units
                cfg.functionName = f
                let m = try? MLModel(contentsOf: url, configuration: cfg)
                guard let self else { return }
                self.lock.lock()
                let alive = self.aneGeneration == gen && self.ready
                if alive {
                    if let m { self.fnModels[f] = m; self.aneLoaded.insert(f) } else { self.aneFailed = true }
                }
                self.lock.unlock()
                if !alive || m == nil { return }
            }
        }
    }

    /// ANE で読み終えた関数の数と全体の数（ANE 版でなければ (0, 0)）
    public var aneProgress: (loaded: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        return functions.isEmpty || computeUnits == .cpuOnly ? (0, 0) : (aneLoaded.count, functions.count)
    }

    /// ANE で全部の関数を読み終えるまで待つ（測る用）。読めなければ false
    @discardableResult
    public func waitForANE(timeout: TimeInterval = 1800) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end && aneProgress.total > 0 {
            lock.lock(); let done = aneLoaded.count == functions.count, failed = aneFailed; lock.unlock()
            if done { return true }
            if failed { return false }
            usleep(100_000)
        }
        return false
    }

    /// いま使える件数。ANE 版は、その件数の関数が全部 ANE に載ってから（それまでは 1 件ずつ）。lock を持って呼ぶ
    private func usableBatchSizes() -> [Int] {
        if functions.isEmpty || computeUnits == .cpuOnly || aneFailed { return batchSizes }
        return batchSizes.filter { b in b == 1 || functions.filter { $0.hasPrefix("b\(b)_") }.allSatisfy(aneLoaded.contains) }
    }

    /// (B, L) に使うモデルと、実際に通す長さ。lock を持って呼ぶ。
    /// ANE を使わない（読めなかった）ときは、その関数を CPU で読む。
    /// ANE の読み込み中は、件数 1 だけ代わりを出す: いちばん長い関数（b1_s128）に詰めて通す（ANE で読めていれば ANE、
    /// まだなら CPU で 1 つだけ読む。CPU で読んだ関数は 1 つで resident 約 500MB・~/Library/Caches に約 500MB 増えるので、増やさない）。
    /// 件数 8 は代わりを出さない（nil。呼ぶ側が 1 件ずつに回す）
    private func modelFor(B: Int, L: Int) -> (MLModel, Int)? {
        let key = "b\(B)_s\(L)"
        let cpuMode = computeUnits == .cpuOnly || aneFailed
        if let m = fnModels[key], cpuMode || aneLoaded.contains(key) { return (m, L) }
        guard let url = fnURL, functions.contains(key) else { return nil }
        func cpu(_ k: String) -> MLModel? {
            if let m = fnModels[k] { return m }
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .cpuOnly
            cfg.functionName = k
            let m = try? MLModel(contentsOf: url, configuration: cfg)
            fnModels[k] = m
            return m
        }
        if cpuMode { return cpu(key).map { ($0, L) } }
        guard B == 1, let longest = shapes.last else { return nil }
        let k = "b1_s\(longest)"
        return cpu(k).map { ($0, longest) }
    }

    /// ANE のキャッシュは .mlmodelc の場所（とファイル）ごとに作られる。アプリの中のモデルは入れ替えのたびに新しいファイルになり、
    /// 初回のコンパイル（数分）からやり直しになるので、中身の印（model.mil のハッシュと重みの大きさ）を名前にした場所に
    /// 1 度だけハードリンク（だめならコピー）して、そこから読む。前の版のリンクは消す
    public static func stableCopy(_ url: URL) throws -> URL {
        // アプリの中のモデルだけ（答え合わせで SSD のモデルを読むときは、そのまま読む）
        guard Bundle.main.bundleURL.pathExtension == "app", url.path.hasPrefix(Bundle.main.bundlePath + "/") else { return url }
        let fm = FileManager.default
        guard let h = milHash(url) else { return url }
        let wsize = (try? fm.attributesOfItem(atPath: url.appendingPathComponent("weights/weight.bin").path)[.size] as? Int) ?? 0
        let dir = RaidenPaths.support.appendingPathComponent("compiled", isDirectory: true)
        let name = "ane-" + String(h, radix: 16) + "-\(wsize).mlmodelc"
        let dst = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: dst.appendingPathComponent("model.mil").path) { return dst }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for old in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where old.hasPrefix("ane-") {
            try? fm.removeItem(at: dir.appendingPathComponent(old))
        }
        do { try fm.linkItem(at: url, to: dst) } catch {
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: url, to: dst)
        }
        return dst
    }

    /// .mlmodelc の model.mil の FNV-1a ハッシュ（10MB で 10ms ほど）
    static func milHash(_ url: URL) -> UInt64? {
        guard let mil = try? Data(contentsOf: url.appendingPathComponent("model.mil"), options: .alwaysMapped) else { return nil }
        var h: UInt64 = 0xcbf29ce484222325
        mil.withUnsafeBytes { raw in for b in raw.bindMemory(to: UInt8.self) { h = (h ^ UInt64(b)) &* 0x100000001b3 } }
        return h
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
        fnReady = false
        fnModels = [:]
        aneLoaded = []
        aneGeneration += 1
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
        guard (try? loadLocked()) != nil, let tok = tokenizer, ready else { return zero }
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
        lock.lock(); _ = try? loadLocked(); let sizes = usableBatchSizes(); lock.unlock()
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
            let vs: [[Float]]? = (try? loadLocked()) != nil && ready ? run(model, rows: chunk.map { ids[$0] }, B: bShape, L: L) : nil
            lock.unlock()
            // まとめて通せなかったら 1 件ずつ
            for (k, j) in chunk.enumerated() { out[j] = vs?[k] ?? embed(texts[j]) }
        }
        return out
    }

    /// 検索の途中（並べ直し）で使う: 入力 1 文と同じく、裏のまとめてのベクトル化より先に通し、終わるまで続けて使う
    public func embedUrgent(_ texts: [String], batch want: Int = 8) -> [[Float]] {
        waitLock.lock(); waiting += 1; waitLock.unlock()
        defer { waitLock.lock(); waiting -= 1; waitLock.unlock() }
        let zero = [Float](repeating: 0, count: dimension)
        lock.lock(); defer { lock.unlock() }
        // ANE 版は関数ごとのモデル（run が modelFor で選ぶ）なので model は nil のことがある。ready で見る
        guard (try? loadLocked()) != nil, ready, let tok = tokenizer else { return texts.map { _ in zero } }
        let ids = texts.map { clip(tok.encode($0).map(Int.init)) }
        let sizes = usableBatchSizes()
        let B = sizes.last { $0 <= max(want, 1) } ?? 1
        var out = [[Float]](repeating: zero, count: texts.count)
        let order = ids.indices.sorted { ids[$0].count < ids[$1].count }
        var i = 0
        while i < order.count {
            let chunk = Array(order[i..<min(i + B, order.count)])
            i += chunk.count
            let L = shapes.first { $0 >= ids[chunk.last!].count } ?? maxTokens
            let bShape = sizes.first { $0 >= chunk.count } ?? B
            if let vs = run(model, rows: chunk.map { ids[$0] }, B: bShape, L: L) {
                for (k, j) in chunk.enumerated() { out[j] = vs[k] }
            } else {
                for j in chunk { out[j] = run(model, rows: [ids[j]], B: 1, L: shapes.first { $0 >= ids[j].count } ?? maxTokens)?.first ?? zero }
            }
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
    private func run(_ base: MLModel?, rows: [[Int]], B: Int, L want: Int) -> [[Float]]? {
        let dim = dimension
        guard let (model, L) = functions.isEmpty ? base.map({ ($0, want) }) : modelFor(B: B, L: want) else { return nil }
        let maskType = model.modelDescription.inputDescriptionsByName["attention_mask"]?.multiArrayConstraint?.dataType ?? .int32
        guard let table,
              let emb = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: L), NSNumber(value: dim)], dataType: .float16),
              let mask = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: L)], dataType: maskType == .float16 ? .float16 : .int32) else { return nil }
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
            if maskType == .float16 {
                let m = raw.bindMemory(to: Float16.self)
                for r in 0..<B {
                    let n = r < rows.count ? rows[r].count : 1
                    for i in 0..<L { m[r * L + i] = i < n ? 1 : 0 }
                }
            } else {
                let m = raw.bindMemory(to: Int32.self)
                for r in 0..<B {
                    let n = r < rows.count ? rows[r].count : 1
                    for i in 0..<L { m[r * L + i] = i < n ? 1 : 0 }
                }
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
