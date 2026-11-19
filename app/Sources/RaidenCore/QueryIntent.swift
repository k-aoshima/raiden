import Foundation

/// 入力から「時間の言葉」と「種類の言葉」を読み取る（ベクトルでは日付も種類も見分けにくいので、コードで絞る）。
///   「昨日いじったやつ」→ range = 昨日 0 時〜今日 0 時
///   「先週ダウンロードしたPDF」→ range = 先週、download、families = [pdf]
public struct QueryIntent: Sendable {
    public var families: Set<String> = []
    public var range: ClosedRange<Int>?   // unix 秒
    public var download = false
    public var rest = ""                  // 時間・種類の言葉を抜いた残り（空なら元の文を使う）
    /// つながりの言い方（「A と同じ日に撮った B」「A の中の B」）。anchor = A（入口を探す側）、target = B（答えの側）
    public var anchor = ""
    public var target = ""
    public var hasRelation: Bool { !anchor.isEmpty }
    /// true: 「A の中の B」（contains をたどる）、false: 「A と同じ日の B」（co_used / co_time をたどる）
    public var inside = false

    public var isEmpty: Bool { families.isEmpty && range == nil && !download }

    // 種類の言葉 → families（FileCatalog.families と同じ名前）。長い言葉から先に見る
    static let typeWords: [(String, String)] = [
        ("スクリーンショット", "screenshot"), ("スクショ", "screenshot"), ("screenshot", "screenshot"), ("キャプチャ", "screenshot"),
        ("画像", "image"), ("写真", "image"), ("イラスト", "image"), ("png", "image"), ("jpg", "image"), ("jpeg", "image"),
        ("image", "image"), ("photo", "image"), ("picture", "image"),
        ("pdf", "pdf"),
        ("動画", "movie"), ("ムービー", "movie"), ("画面収録", "movie"), ("録画", "movie"), ("video", "movie"), ("movie", "movie"), ("mov", "movie"),
        ("エクセル", "sheet"), ("excel", "sheet"), ("表計算", "sheet"), ("スプレッドシート", "sheet"), ("csv", "sheet"), ("xlsx", "sheet"),
        ("ワード", "doc"), ("word", "doc"), ("docx", "doc"), ("文書", "doc"),
        ("テキスト", "text"), ("txt", "text"), ("マークダウン", "text"), ("markdown", "text"),
        ("フォント", "font"), ("font", "font"),
        ("zip", "archive"), ("圧縮", "archive"), ("rar", "archive"),
        ("html", "web"), ("webページ", "web"), ("ウェブページ", "web"),
        ("json", "json"),
        ("フォトショ", "design"), ("photoshop", "design"), ("psd", "design"), ("イラレ", "design"), ("illustrator", "design"),
        ("stl", "3d"), ("glb", "3d"), ("3dモデル", "3d"), ("blender", "3d"),
        ("フォルダ", "folder"), ("ディレクトリ", "folder"), ("folder", "folder"), ("入ってるとこ", "folder"), ("入ってる場所", "folder"),
        ("置き場", "folder"), ("ところ", "folder"), ("とこ", "folder"), ("場所", "folder"), ("一式", "folder"),
    ]

    /// つながりの言葉（長いものから）。前が anchor、後ろが target
    static let relationWords = [
        "と同じフォルダにある", "と同じフォルダの", "と同じ日に", "と同じ日の", "と同じころに", "と同じころ", "と一緒に", "と同じ時に",
        "のすぐ後に", "のすぐあとに", "のすぐ後の", "の後にダウンロードした", "を作った日に", "を作ってた日に",
        "の中にある", "の中の", "に入ってる", "に入っている", "にある",
    ]

    static let downloadWords = ["ダウンロード", "落とした", "download"]

    public static func parse(_ query: String, now: Date = Date()) -> QueryIntent {
        var it = QueryIntent()
        let q = query.precomposedStringWithCompatibilityMapping.lowercased()
        var rest = q
        // つながり: 種類の言葉は答えの側（後ろ）だけで読む
        var typeScope = q
        for w in relationWords {
            if let r = q.range(of: w) {
                it.anchor = String(q[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                it.target = String(q[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                typeScope = it.target
                it.inside = ["の中にある", "の中の", "に入ってる", "に入っている", "にある", "と同じフォルダにある", "と同じフォルダの"].contains(w)
                if it.anchor.count < 2 { it.anchor = ""; it.target = ""; typeScope = q }
                break
            }
        }
        for (w, f) in typeWords where typeScope.contains(w) {
            it.families.insert(f)
            rest = rest.replacingOccurrences(of: w, with: " ")
        }
        if it.families.contains("screenshot") { it.families.remove("image") }
        for w in downloadWords where q.contains(w) { it.download = true; rest = rest.replacingOccurrences(of: w, with: " ") }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: today)! }
        func r(_ a: Date, _ b: Date) -> ClosedRange<Int> { Int(a.timeIntervalSince1970)...Int(b.timeIntervalSince1970) - 1 }
        let week = cal.dateInterval(of: .weekOfYear, for: now)!
        let month = cal.dateInterval(of: .month, for: now)!
        let year = cal.dateInterval(of: .year, for: now)!
        let fixed: [(String, ClosedRange<Int>)] = [
            ("おととい", r(day(-2), day(-1))), ("一昨日", r(day(-2), day(-1))),
            ("昨日", r(day(-1), today)), ("きのう", r(day(-1), today)), ("yesterday", r(day(-1), today)),
            ("今日", r(today, day(1))), ("きょう", r(today, day(1))), ("today", r(today, day(1))),
            ("さっき", r(now.addingTimeInterval(-3 * 3600), now.addingTimeInterval(60))),
            ("先週", r(cal.date(byAdding: .day, value: -7, to: week.start)!, week.start)),
            ("last week", r(cal.date(byAdding: .day, value: -7, to: week.start)!, week.start)),
            ("今週", r(week.start, week.end)), ("this week", r(week.start, week.end)),
            ("先月", r(cal.date(byAdding: .month, value: -1, to: month.start)!, month.start)),
            ("今月", r(month.start, month.end)),
            ("去年", r(cal.date(byAdding: .year, value: -1, to: year.start)!, year.start)),
            ("昨年", r(cal.date(byAdding: .year, value: -1, to: year.start)!, year.start)),
            ("今年", r(year.start, year.end)),
            ("最近", r(day(-14), day(1))), ("この前", r(day(-14), day(1))), ("こないだ", r(day(-14), day(1))),
            ("recent", r(day(-14), day(1))),
        ]
        for (w, rg) in fixed where q.contains(w) {
            it.range = rg
            rest = rest.replacingOccurrences(of: w, with: " ")
            break
        }
        if it.range == nil, let m = q.range(of: "([0-9]+)(日|週間|か月|ヶ月|カ月)前", options: .regularExpression) {
            let s = String(q[m])
            let n = Int(s.prefix { $0.isNumber }) ?? 0
            if s.contains("日") { it.range = r(day(-n - 1), day(-n + 2)) }
            else if s.contains("週") { it.range = r(day(-7 * n - 4), day(-7 * n + 4)) }
            else { it.range = r(cal.date(byAdding: .day, value: -30 * n - 15, to: today)!, cal.date(byAdding: .day, value: -30 * n + 15, to: today)!) }
            rest.removeSubrange(rest.range(of: s) ?? rest.startIndex..<rest.startIndex)
        }
        if it.range == nil, let m = q.range(of: "(20[0-9]{2})年", options: .regularExpression) {
            let y = Int(q[m].prefix(4))!
            let a = cal.date(from: DateComponents(year: y, month: 1, day: 1))!
            it.range = r(a, cal.date(byAdding: .year, value: 1, to: a)!)
            rest = rest.replacingOccurrences(of: String(q[m]), with: " ")
        } else if it.range == nil, let m = q.range(of: "(?<![0-9])(1[0-2]|[1-9])月(?!分)", options: .regularExpression) {
            // 「10月の」。未来なら去年の同じ月。「10月分」は名前の一部なので読まない
            let mo = Int(q[m].dropLast())!
            var y = cal.component(.year, from: now)
            if mo > cal.component(.month, from: now) { y -= 1 }
            let a = cal.date(from: DateComponents(year: y, month: mo, day: 1))!
            it.range = r(a, cal.date(byAdding: .month, value: 1, to: a)!)
            rest = rest.replacingOccurrences(of: String(q[m]), with: " ")
        }
        // 残りから「やつ」「した」など中身の無い言葉を落とす
        for w in ["いじった", "使った", "開いた", "見た", "作った", "した", "やつ", "もの", "ファイル"] {
            rest = rest.replacingOccurrences(of: w, with: " ")
        }
        let t = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(CharacterSet(charactersIn: "のをにでがはとも")))
        it.rest = t.count >= 2 ? rest.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ") : ""
        return it
    }
}
