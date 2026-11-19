import Foundation
import NaturalLanguage

/// 文をベクトル（長さ 1 に揃えたもの）にする。
public protocol Embedder: AnyObject {
    var identifier: String { get }
    var dimension: Int { get }
    func embed(_ text: String) -> [Float]
}

public enum EmbedderError: Error { case unavailable, assets(String) }

/// OS に入っている NLContextualEmbedding（モデルを同梱しない）。
/// トークンごとのベクトルを平均して 1 本にする。
public final class NLEmbedder: Embedder {
    private let model: NLContextualEmbedding
    private let lock = NSLock()
    public let identifier: String
    public let dimension: Int

    public init(language: NLLanguage = .japanese) throws {
        guard let m = NLContextualEmbedding(language: language) else { throw EmbedderError.unavailable }
        if !m.hasAvailableAssets {
            // 初回だけ OS がモデルを落としてくる
            let sem = DispatchSemaphore(value: 0)
            var failure: String?
            m.requestAssets { result, err in
                if result != .available { failure = err?.localizedDescription ?? "assets \(result.rawValue)" }
                sem.signal()
            }
            sem.wait()
            if let f = failure { throw EmbedderError.assets(f) }
        }
        try m.load()
        model = m
        identifier = "nl:" + m.modelIdentifier
        dimension = m.dimension
    }

    public func embed(_ text: String) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        var v = [Float](repeating: 0, count: dimension)
        guard !text.isEmpty, let r = try? model.embeddingResult(for: text, language: .japanese) else { return v }
        var n = 0
        r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { t, _ in
            for i in 0..<min(t.count, v.count) { v[i] += Float(t[i]) }
            n += 1
            return true
        }
        return Vec.normalized(v)
    }
}

public enum Vec {
    public static func normalized(_ v: [Float]) -> [Float] {
        var s: Float = 0
        for x in v { s += x * x }
        let n = s.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    @inline(__always)
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for i in 0..<min(pa.count, pb.count) { s += pa[i] * pb[i] }
            }
        }
        return s
    }
}
