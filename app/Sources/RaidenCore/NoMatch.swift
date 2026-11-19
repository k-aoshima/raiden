import Foundation

/// 「見つからない」の判定に使う手がかり（1 回の検索ぶん）
public struct MatchSignals: Sendable, CustomStringConvertible {
    public var top1: Float = 0        // 1 位の点数
    public var top2: Float = 0        // 2 位の点数
    public var gap: Float { top1 - top2 }
    public var gapNoEx: Float = 0     // 例（k近傍法）を抜いて並べたときの 1 位と 2 位の差
    public var nameHit = false        // 1 位の名前が入力と文字で一致（先頭・途中・ローマ字）
    public var rawV: Float = 0        // 1 位の説明文との素の近さ（加点の前）
    public var maxV: Float = 0        // 全部の点の中で一番の素の近さ
    public var vGap: Float = 0        // 素の近さの 1 番と 2 番の差
    public var vZ: Float = 0          // maxV が全体の近さの分布から何σ離れているか
    public var knnSim: Float = 0      // 一番近い例との近さ（例が無ければ 0）
    public var hasIntent = false      // 時間・種類の言葉があった
    public var relation = false       // 「A と同じ日の B」のようなつながりの言い方で並べた
    public init() {}

    public var description: String {
        String(format: "1位 %.3f 差 %.3f（例抜き %.3f） 名前 %@ V %.3f maxV %.3f 例 %.3f%@%@",
               top1, gap, gapNoEx, nameHit ? "○" : "-", rawV, maxV, knnSim,
               hasIntent ? " 絞込" : "", relation ? " つながり" : "")
    }
}

/// 「見つからない」の判定。弾いても候補は消さず、印（noMatch）を付けるだけ（画面で薄く出せるように）。
/// しきい値は raiden-eval --files --section nomatch で決めた（README 参照）。
///
///   残す: 名前が文字で一致 / つながりの言い方 / 近い例がある（knnSim ≥ keepKnnSim）
///   弾く: 素の近さの一番（maxV）が lowMaxV 未満、または midMaxV 未満で 1 位と 2 位の差（例抜き）が maxGap 未満
///
/// 答えの無い入力は「どれにもそこそこ近く、どれも抜けていない」形になる（1 位の点数だけだと、
/// 時間・種類の加点や名前の一致で上がった点と区別できない）。
public struct NoMatchRule: Sendable {
    public var lowMaxV: Float
    public var midMaxV: Float
    public var maxGap: Float
    public var keepKnnSim: Float

    public init(lowMaxV: Float, midMaxV: Float, maxGap: Float, keepKnnSim: Float) {
        self.lowMaxV = lowMaxV; self.midMaxV = midMaxV; self.maxGap = maxGap; self.keepKnnSim = keepKnnSim
    }

    /// しきい値の数字（ここにまとめる）
    public enum Thresholds {
        // ファイル・フォルダ
        public static let fileLowMaxV: Float = 0.46
        public static let fileMidMaxV: Float = 0.55
        public static let fileMaxGap: Float = 0.03
        public static let fileKeepKnnSim: Float = 0.68
        // アプリ（件数が少なく例が必ず効くので、差は見ずに素の近さがかなり低いときだけ弾く）
        public static let appLowMaxV: Float = 0.47
        public static let appKeepKnnSim: Float = 0.55
    }

    public static let files = NoMatchRule(lowMaxV: Thresholds.fileLowMaxV, midMaxV: Thresholds.fileMidMaxV,
                                          maxGap: Thresholds.fileMaxGap, keepKnnSim: Thresholds.fileKeepKnnSim)
    public static let apps = NoMatchRule(lowMaxV: Thresholds.appLowMaxV, midMaxV: 0, maxGap: 0,
                                         keepKnnSim: Thresholds.appKeepKnnSim)

    public func isNoMatch(_ s: MatchSignals) -> Bool {
        if s.nameHit || s.relation || s.knnSim >= keepKnnSim { return false }
        return s.maxV < lowMaxV || (s.maxV < midMaxV && s.gapNoEx < maxGap)
    }
}

/// 検索の結果と「見つからない」の印
public struct Judged<R: Sendable>: Sendable {
    public let results: [R]          // 弾いたときも点数の順に残す（画面で薄く出す用）
    public let noMatch: Bool         // true なら「見つからない」と出し、results は控えめに見せる
    public let signals: MatchSignals
}

public enum NoMatch {
    /// ranked（Ranker.rank の結果）と入力から手がかりを集める。
    /// rankedNoEx は例（k近傍法）を抜いて並べた結果（例が無ければ nil で ranked を使う）
    public static func signals(_ c: Corpus, query q: String, vec v: [Float], mix m: Mix,
                               ranked: [(Int, Float)], rankedNoEx: [(Int, Float)]?,
                               intent: QueryIntent?, relation: Bool) -> MatchSignals {
        var s = MatchSignals()
        guard let first = ranked.first else { return s }
        s.top1 = first.1
        s.top2 = ranked.count > 1 ? ranked[1].1 : first.1 - 1
        let r0 = rankedNoEx ?? ranked
        s.gapNoEx = r0.count > 1 ? r0[0].1 - r0[1].1 : 1
        s.relation = relation
        s.hasIntent = !(intent?.isEmpty ?? true)
        let V = c.dots(v)
        if !V.isEmpty {
            s.rawV = V[first.0]
            var a: Float = -9, b: Float = -9, sum: Float = 0
            for x in V { sum += x; if x > a { b = a; a = x } else if x > b { b = x } }
            s.maxV = a
            s.vGap = V.count > 1 ? a - b : 0
            let mean = sum / Float(V.count)
            let sd = (V.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(V.count)).squareRoot()
            s.vZ = sd > 0 ? (a - mean) / sd : 0
        }
        s.nameHit = nameHit(c, query: q, index: first.0, mix: m)
        if m.k { for ev in c.exVecs { s.knnSim = max(s.knnSim, Vec.dot(ev, v)) } }
        return s
    }

    /// Ranker と同じ名前の文字一致（先頭・単語の先頭・途中・ローマ字の 1 文字違いまで）
    static func nameHit(_ c: Corpus, query q: String, index i: Int, mix m: Mix) -> Bool {
        let nq = Lexical.normalize(q)
        let asciiQ = nq.allSatisfy { $0.isASCII }
        if nq.isEmpty || (asciiQ && nq.count < 2) { return false }
        for nn in c.names[i] {
            let words = nn.split(whereSeparator: { " -_.".contains($0) })
            if nn.contains(nq) || words.contains(where: { $0.hasPrefix(nq) }) { return true }
        }
        let rq = asciiQ ? Lexical.canonRomaji(nq.filter { $0.isLetter || $0.isNumber }) : ""
        if m.fuzzyBonus > 0 && rq.count >= 3 && !c.romaji[i].isEmpty {
            let d = Lexical.approxSubstringDistance(rq, in: c.romaji[i])
            if d == 0 || (d == 1 && rq.count >= 4) { return true }
        }
        return false
    }
}
