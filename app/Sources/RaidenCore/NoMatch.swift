import Foundation

/// 「見つからない」の判定に使う手がかり（1 回の検索ぶん）
public struct MatchSignals: Sendable, CustomStringConvertible {
    public var top1: Float = 0        // 1 位の点数
    public var top2: Float = 0        // 2 位の点数
    public var gap: Float { top1 - top2 }
    public var nameHit = false        // 1 位の名前が入力と文字で一致（先頭・途中・ローマ字）
    public var dictHit = false        // 1 位の辞書の言葉に入力の文字が入っている
    public var exampleHit = false     // 1 位に「選んだ」記録が当たった
    public var fetched = 0            // ファイル: Spotlight から受け取った件数（ふるう前）
    public var ms: Double = 0         // ファイル: Spotlight の問い合わせの時間
    public init() {}

    public var description: String {
        String(format: "1位 %.3f 差 %.3f 名前 %@ 辞書 %@ 記録 %@", top1, gap, nameHit ? "○" : "-", dictHit ? "○" : "-", exampleHit ? "○" : "-")
    }
}

/// 検索の結果と「見つからない」の印。弾いても候補は消さず、印（noMatch）を付けるだけ（画面で薄く出せるように）。
///   アプリ: 1 位が名前・辞書・「選んだ」記録のどれにも当たっていない
///   ファイル・フォルダ: Spotlight の結果が 0 件（条件に合う物が無い）
public struct Judged<R: Sendable>: Sendable {
    public let results: [R]          // 弾いたときも点数の順に残す（画面で薄く出す用）
    public let noMatch: Bool         // true なら「見つからない」と出し、results は控えめに見せる
    public let signals: MatchSignals
    /// 入力欄のコマンドの読み取り結果（コマンドが無い入力では nil）。検索の記録（SearchLog）に残す用
    public var filters: QueryFilters? = nil
    /// 候補が多いときの絞り込みの問い（ファイルの検索だけ）と、条件に合った件数
    public var split: RecallSplit? = nil
    public var total = 0
    public init(results: [R], noMatch: Bool, signals: MatchSignals, filters: QueryFilters? = nil) {
        self.results = results; self.noMatch = noMatch; self.signals = signals; self.filters = filters
    }
}
