import Foundation

/// ファイル・フォルダのベクトルの 2 値の形（1024 次元 → 1024 ビット = 128 バイト。各次元の符号が 1 なら 1）。
/// データベースとメモリにはこれだけを置き、細かいベクトル（float32 4KB）は持たない。
///
/// 近さは「非対称の内積」: 入力は float32 のまま、文書は ±1 として内積を取る（mixedbread の Binary MRL と同じ考え）。
/// 1 バイト（8 次元）ごとに 256 通りの和を先に作っておき（128 × 256 の表）、文書 1 件は表を 128 回引くだけ。
/// ハミング距離（入力も 2 値にする）より当たりが良い（raiden-eval --files --bin-mode で比べた。README 参照）。
/// 2 値にする前に中心（center.bin、bge-m3 の次元ごとの平均）を引く。次元ごとの平均が 0 から大きくずれているので、
/// 引かないとほとんどの文書で同じビットが立つ（tools/convert/make_center.py）。
/// 点数は cos と同じ目盛りに合わせる: a × (q・s)/32 + (q・center) + b（上位 50 件で最小二乗。q・center は入力ごとに一定で並び順には効かない）。
public enum BinVec {
    public static let bytes = 128

    public enum Mode: String, Sendable { case asym, hamming, twoStage }
    /// 並べ方（答え合わせで比べる用。既定は非対称の内積で全件）
    nonisolated(unsafe) public static var mode: Mode = .asym
    /// twoStage でハミング距離で絞る件数
    nonisolated(unsafe) public static var twoStageN = 100
    /// 中心（1024 次元）。無ければ引かない（そのときの目盛りは asymA0 / asymB0）
    nonisolated(unsafe) public private(set) static var center: [Float]?
    /// 非対称の内積を cos の目盛りに（2026-11-20、手元 1,066 件の float32 と例 16 個・アプリ 133 個の上位 50 件で最小二乗）
    ///   中心あり: cos ≈ 0.64 × x + (q・center) + 0.015（残差 0.016）。中心なし: cos ≈ 1.097 × x + 0.135（残差 0.02）
    nonisolated(unsafe) public static var asymA: Float = 0.64
    nonisolated(unsafe) public static var asymB: Float = 0.015
    static let asymA0: Float = 1.097, asymB0: Float = 0.135

    /// center.bin を読む（BGEEmbedder がモデルのフォルダから呼ぶ）
    public static func loadCenter(_ url: URL) {
        guard let d = try? Data(contentsOf: url), d.count == bytes * 8 * 4 else { return }
        center = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    /// ハミング距離の近さ（1 - 2h/1024）を cos の目盛りに: a × x + b
    nonisolated(unsafe) public static var hamA: Float = 0.991
    nonisolated(unsafe) public static var hamB: Float = 0.214

    /// 符号で 2 値にする（次元 8j+k → j バイト目の k ビット）
    public static func encode(_ v: [Float]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bytes)
        let c = center
        for j in 0..<min(bytes, v.count / 8) {
            var b: UInt8 = 0
            for k in 0..<8 where v[j * 8 + k] > (c?[j * 8 + k] ?? 0) { b |= 1 << UInt8(k) }
            out[j] = b
        }
        return out
    }

    /// 2 値から ±1/√1024 のベクトルに戻す（アプリと同じ Corpus の式に通す用・確かめ用）
    public static func decode(_ c: ArraySlice<UInt8>) -> [Float] {
        var v = [Float](repeating: -1 / 32, count: bytes * 8)
        for (j, b) in c.enumerated() { for k in 0..<8 where b & (1 << UInt8(k)) != 0 { v[j * 8 + k] = 1 / 32 } }
        return v
    }

    /// 1 件の非対称の内積（cos の目盛り）。並べ直しで 2 値の近さとの差を見る用
    public static func asymScore(_ c: ArraySlice<UInt8>, q: [Float]) -> Float {
        var acc: Float = 0
        for (j, b) in c.enumerated() {
            for k in 0..<8 { acc += b & (1 << UInt8(k)) != 0 ? q[j * 8 + k] : -q[j * 8 + k] }
        }
        let (a, off) = scale(q)
        return acc / 32 * a + off
    }

    /// 目盛り（a と、入力ごとの足し算 q・center + b）
    static func scale(_ q: [Float]) -> (Float, Float) {
        guard let c = center else { return (asymA0, asymB0) }
        var qm: Float = 0
        for i in 0..<min(q.count, c.count) { qm += q[i] * c[i] }
        return (asymA, qm + asymB)
    }

    /// 全件の近さ。codes は n 件 × 128 バイトを 1 本に並べたもの
    public static func scores(codes: [UInt8], n: Int, query q: [Float]) -> [Float] {
        guard n > 0, q.count >= bytes * 8 else { return [Float](repeating: 0, count: n) }
        switch mode {
        case .asym: return asym(codes: codes, n: n, q: q, only: nil)
        case .hamming: return hamming(codes: codes, n: n, q: q)
        case .twoStage:
            var h = hamming(codes: codes, n: n, q: q)
            let top = Ranker.topIndices(h, min(twoStageN, n))
            let a = asym(codes: codes, n: n, q: q, only: top)
            for i in top { h[i] = a[i] }
            return h
        }
    }

    /// 非対称の内積。only を渡すとその添字だけ計算する（ほかは 0）
    static func asym(codes: [UInt8], n: Int, q: [Float], only: [Int]?) -> [Float] {
        // 表: lut[j*256 + b] = Σ_k (b の k ビットが 1 なら +q[8j+k]、0 なら -q[8j+k]) / 32 × a
        var lut = [Float](repeating: 0, count: bytes * 256)
        let (a, off) = scale(q)
        let s = a / 32
        for j in 0..<bytes {
            var base: Float = 0
            for k in 0..<8 { base -= q[j * 8 + k] }
            for b in 0..<256 {
                var x = base
                for k in 0..<8 where b & (1 << k) != 0 { x += 2 * q[j * 8 + k] }
                lut[j * 256 + b] = x * s
            }
        }
        var out = [Float](repeating: 0, count: n)
        codes.withUnsafeBufferPointer { c in lut.withUnsafeBufferPointer { t in
            func one(_ i: Int) -> Float {
                var acc: Float = off
                let o = i * bytes
                for j in 0..<bytes { acc += t[j * 256 + Int(c[o + j])] }
                return acc
            }
            if let only { for i in only { out[i] = one(i) } } else { for i in 0..<n { out[i] = one(i) } }
        } }
        return out
    }

    /// ハミング距離の近さ（入力も 2 値にする）。a × (1 - 2h/1024) + b
    static func hamming(codes: [UInt8], n: Int, q: [Float]) -> [Float] {
        let qc = encode(q)   // 入力も中心を引いて 2 値に
        var out = [Float](repeating: 0, count: n)
        let words = bytes / 8
        qc.withUnsafeBytes { qr in codes.withUnsafeBytes { cr in
            let qw = qr.bindMemory(to: UInt64.self), cw = cr.bindMemory(to: UInt64.self)
            for i in 0..<n {
                var h = 0
                for w in 0..<words { h += (qw[w] ^ cw[i * words + w]).nonzeroBitCount }
                out[i] = (1 - 2 * Float(h) / Float(bytes * 8)) * hamA + hamB
            }
        } }
        return out
    }
}
