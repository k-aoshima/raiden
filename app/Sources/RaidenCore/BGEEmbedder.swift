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
        model = try MLModel(contentsOf: try BGEEmbedder.compiled(bodyURL), configuration: cfg)
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
        lock.lock(); defer { lock.unlock() }
        let zero = [Float](repeating: 0, count: dimension)
        guard (try? loadLocked()) != nil, let tok = tokenizer, let model, let table else { return zero }
        var ids = tok.encode(text).map(Int.init)
        if ids.count > maxTokens { ids = Array(ids.prefix(maxTokens - 1)) + [ids.last!] }
        let L = shapes.first { $0 >= ids.count } ?? maxTokens
        let dim = dimension
        guard let emb = try? MLMultiArray(shape: [1, NSNumber(value: L), NSNumber(value: dim)], dataType: .float16),
              let mask = try? MLMultiArray(shape: [1, NSNumber(value: L)], dataType: .int32) else { return zero }
        emb.withUnsafeMutableBytes { raw, _ in
            let dst = raw.bindMemory(to: Float16.self)
            for i in 0..<(L * dim) { dst[i] = 0 }
            table.withUnsafeBytes { tb in
                let src = tb.bindMemory(to: Int8.self)
                for (t, id) in ids.enumerated() where id >= 0 && id < vocab {
                    let s = scales[id]
                    let o = id * dim, d = t * dim
                    for j in 0..<dim { dst[d + j] = Float16(Float(src[o + j]) * s) }
                }
            }
        }
        mask.withUnsafeMutableBytes { raw, _ in
            let m = raw.bindMemory(to: Int32.self)
            for i in 0..<L { m[i] = i < ids.count ? 1 : 0 }
        }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [
                "inputs_embeds": MLFeatureValue(multiArray: emb),
                "attention_mask": MLFeatureValue(multiArray: mask)]),
              let out = try? model.prediction(from: input),
              let arr = out.featureValue(for: "embedding")?.multiArrayValue else { return zero }
        var v = [Float](repeating: 0, count: dim)
        if arr.dataType == .float32 {
            arr.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: Float.self)
                for i in 0..<dim { v[i] = p[i] }
            }
        } else {
            for i in 0..<dim { v[i] = arr[i].floatValue }
        }
        return Vec.normalized(v)
    }
}
