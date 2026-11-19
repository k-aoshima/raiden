import Foundation

/// bge-m3（XLM-RoBERTa）の SentencePiece Unigram を Swift で動かす最小実装。
///
/// swift-transformers の Tokenizers は使えるが、この Mac の Command Line Tools では
/// SwiftPM（Package.swift）のリンクが落ちて依存を取り込めないため、必要な分だけ自前で書いた。
/// 語彙は vocab.bin（tools/convert/export_tokenizer.py が作る）を mmap し、二分探索で引く。
/// mmap なので、語彙 25 万件はメモリ（footprint）にほぼ乗らない。
///
/// 手順は tokenizer.json と同じ:
///   正規化（Precompiled = nmt_nfkc を NFKC で近似 → 2 個以上の空白を 1 個に）
///   → Metaspace（空白を ▁ に、先頭に ▁、▁ の前で区切る）→ 単語ごとに Viterbi → <s> … </s>
public final class UnigramTokenizer {
    private let data: Data
    private let count: Int
    public let unkID: Int32
    private let unkScore: Float
    private let offBase: Int, idBase: Int, scoreBase: Int, strBase: Int
    public static let bos: Int32 = 0, eos: Int32 = 2
    private static let maxPieceScalars = 16

    public init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count > 16, data.prefix(4) == Data("RVOC".utf8) else { throw EmbedderError.unavailable }
        let n = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
        count = n
        unkID = data.withUnsafeBytes { Int32($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) }
        let minScore = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: Float.self) }
        unkScore = minScore - 10  // HF tokenizers の kUnkPenalty
        offBase = 16
        idBase = offBase + 4 * (n + 1)
        scoreBase = idBase + 4 * n
        strBase = scoreBase + 4 * n
    }

    /// バイト列を語彙から引く。見つかれば (id, score)
    private func lookup(_ key: UnsafeBufferPointer<UInt8>) -> (Int32, Float)? {
        data.withUnsafeBytes { raw -> (Int32, Float)? in
            let base = raw.baseAddress!
            var lo = 0, hi = count - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                let a = Int(raw.loadUnaligned(fromByteOffset: offBase + 4 * mid, as: UInt32.self))
                let b = Int(raw.loadUnaligned(fromByteOffset: offBase + 4 * mid + 4, as: UInt32.self))
                let len = b - a
                let c = memcmp(base + strBase + a, key.baseAddress!, min(len, key.count))
                let cmp = c != 0 ? Int(c) : len - key.count
                if cmp == 0 {
                    return (raw.loadUnaligned(fromByteOffset: idBase + 4 * mid, as: Int32.self),
                            raw.loadUnaligned(fromByteOffset: scoreBase + 4 * mid, as: Float.self))
                }
                if cmp < 0 { lo = mid + 1 } else { hi = mid - 1 }
            }
            return nil
        }
    }

    static func normalize(_ s: String) -> String {
        var t = s.precomposedStringWithCompatibilityMapping
        // nmt_nfkc は制御文字を消し、タブや改行などの空白を半角空白にする
        t = String(String.UnicodeScalarView(t.unicodeScalars.compactMap { u -> Unicode.Scalar? in
            if u.properties.generalCategory == .control { return (u == "\t" || u == "\n" || u == "\r") ? " " : nil }
            if u.properties.isWhitespace { return " " }
            return u
        }))
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t
    }

    /// 単語 1 個（先頭が ▁）を Viterbi で区切る
    private func viterbi(_ word: [Unicode.Scalar], into out: inout [Int32]) {
        let n = word.count
        if n == 0 { return }
        // 各位置の UTF-8 バイト位置
        var bytes: [UInt8] = []
        var pos = [Int](repeating: 0, count: n + 1)
        for (i, u) in word.enumerated() {
            pos[i] = bytes.count
            bytes.append(contentsOf: Array(String(u).utf8))
        }
        pos[n] = bytes.count
        var best = [Float](repeating: -.infinity, count: n + 1)
        var back = [(Int, Int32)](repeating: (0, 0), count: n + 1)
        best[0] = 0
        bytes.withUnsafeBufferPointer { bp in
            for i in 0..<n where best[i] > -.infinity {
                var single = false
                for len in 1...min(UnigramTokenizer.maxPieceScalars, n - i) {
                    let key = UnsafeBufferPointer(rebasing: bp[pos[i]..<pos[i + len]])
                    if let (id, sc) = lookup(key) {
                        if len == 1 { single = true }
                        if best[i] + sc > best[i + len] { best[i + len] = best[i] + sc; back[i + len] = (i, id) }
                    }
                }
                if !single, best[i] + unkScore > best[i + 1] {
                    best[i + 1] = best[i] + unkScore; back[i + 1] = (i, unkID)
                }
            }
        }
        var ids: [Int32] = []
        var j = n
        while j > 0 { let (i, id) = back[j]; ids.append(id); j = i }
        for id in ids.reversed() {
            if id == unkID, out.last == unkID { continue }  // 連続する unk は 1 個にまとめる
            out.append(id)
        }
    }

    public func encode(_ text: String) -> [Int32] {
        var t = UnigramTokenizer.normalize(text).replacingOccurrences(of: " ", with: "▁")
        if !t.hasPrefix("▁") { t = "▁" + t }
        var out: [Int32] = [UnigramTokenizer.bos]
        var word: [Unicode.Scalar] = []
        for u in t.unicodeScalars {
            if u == "▁" && !word.isEmpty { viterbi(word, into: &out); word = [] }
            word.append(u)
        }
        viterbi(word, into: &out)
        out.append(UnigramTokenizer.eos)
        return out
    }
}
