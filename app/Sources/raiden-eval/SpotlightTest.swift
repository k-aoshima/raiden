// Spotlight への置き換えの確かめと、実際の問い合わせの時間。
//
//   raiden-eval --test-spotlight     「#」と言い方が正しい Spotlight の条件になるか（問い合わせはしない）、#near のプロジェクトの根
//                                    （~/Project の実物を読むだけ）、除外・種類・「選んだ」記録の加点
//   raiden-eval --bench-spotlight --file-store <scratch の新しいファイル>   いくつかの入力で Mac 全域に問い合わせた時間と件数、取り消しの速さ
//   raiden-eval --boot-bench --file-store <scratch の新しいファイル>        起動（DB を開く・アプリ一覧・記録）から検索できるまでの時間とメモリ
import Foundation
import RaidenCore

private var spFail = 0
private var spChecks = 0
private func ok(_ c: Bool, _ msg: @autoclosure () -> String) {
    spChecks += 1
    if !c { spFail += 1; print("  NG " + msg()) }
}

private let spNow: Date = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    return f.date(from: "2026-11-19 12:00")!
}()
private func day(_ s: String) -> Int {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    return Int(f.date(from: s)!.timeIntervalSince1970)
}
private func isoUTC(_ t: Int) -> String {
    let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")
    return "$time.iso(" + f.string(from: Date(timeIntervalSince1970: TimeInterval(t))) + ")"
}

func runSpotlightTests() {
    print("== Spotlight への置き換え（基準日 2026-11-19）")
    func req(_ q: String) -> SpotlightSearch.Request {
        let f = QueryFilters.parse(q, now: spNow)
        return f.hasSyntax ? SpotlightSearch.request(f, now: spNow) : SpotlightSearch.request(text: q, now: spNow)
    }
    func qs(_ q: String) -> String { SpotlightSearch.queryString(req(q)) }
    func has(_ q: String, _ parts: [String], not: [String] = []) {
        let s = qs(q)
        ok(parts.allSatisfy(s.contains) && !not.contains(where: s.contains), "「\(q)」 → \(s)")
    }
    let nameReq = "(kMDItemDisplayName == \"*請求書*\"cd || kMDItemFSName == \"*請求書*\"cd)"
    // 名前
    has("請求書", [nameReq])
    ok(req("請求書 2024").words == ["請求書", "2024"], "言葉は空白で分ける（言葉どうしは「または」）")
    has("請求書 2024", [nameReq, " || ", "*2024*\"cd"])
    ok(SpotlightSearch.words("大阪で泊まった宿の領収書") == ["大阪", "領収書"], "ひらがなの所で区切り、1 文字の語は捨てる（\(SpotlightSearch.words("大阪で泊まった宿の領収書"))）")
    ok(SpotlightSearch.words("カードの明細PDFが入ってるとこ") == ["カード", "明細", "PDF"], "英数字とそれ以外の境目でも区切る（\(SpotlightSearch.words("カードの明細PDFが入ってるとこ"))）")
    ok(SpotlightSearch.words("せいきゅう") == ["せいきゅう"], "ひらがなだけの入力は 1 語")
    ok(SpotlightSearch.words("resume of my skills") == ["resume", "skills"], "英語は 2 文字以下の語を捨てる")
    ok(SpotlightSearch.words("請求書") == ["請求書"] && SpotlightSearch.words("pd") == ["pd"], "言葉が 1 つならそのまま（英数字 2 文字も）")
    has("#name 請求", ["kMDItemDisplayName == \"*請求*\"cd", "kMDItemFSName == \"*請求*\"cd"])
    has("#name 請求 #name 見積", ["*請求*", " || ", "*見積*"])
    has("#name a\"b", ["*a\\\"b*"])
    has("100*", ["*100\\**"])
    ok(req("r").words.isEmpty, "英数字 1 文字は名前の言葉にしない")
    // 種類
    has("#kind pdf", ["kMDItemContentTypeTree == \"com.adobe.pdf\"", "kMDItemFSName == \"*.pdf\"c"])
    has("#kind image", ["kMDItemContentTypeTree == \"public.image\""])
    has("#kind ss", ["public.image", "*スクリーンショット*\"cd", "*screenshot*\"cd"])
    has("#kind movie", ["public.movie", "*.mp4\"c", "*.mov\"c"])
    has("#kind audio", ["public.audio", "*.mp3\"c"])
    has("#kind doc", ["org.openxmlformats.wordprocessingml.document", "*.docx\"c", "*.pages\"c"])
    has("#kind xls", ["public.spreadsheet", "*.xlsx\"c", "*.csv\"c"])
    has("#kind ppt", ["public.presentation", "*.pptx\"c", "*.key\"c"])
    has("#kind md", ["*.md\"c", "*.markdown\"c"], not: ["ContentTypeTree"])
    has("#kind code", ["public.source-code", "*.swift\"c"])
    has("#kind archive", ["public.archive", "*.zip\"c"])
    has("#kind folder", ["kMDItemContentTypeTree == \"public.folder\""])
    has("#kind pdf,image", ["com.adobe.pdf", " || ", "public.image"])
    has("#kind pdf,docx", ["com.adobe.pdf", "*.docx\"c"])
    // 拡張子・対象
    has("#ext pdf", ["kMDItemFSName == \"*.pdf\"c"], not: ["ContentTypeTree"])
    has("#ext pdf,docx", ["*.docx\"c", " || ", "*.pdf\"c"])
    has("#type d", ["kMDItemContentType == \"public.folder\""])
    has("#type f", ["kMDItemContentType != \"public.folder\""])
    ok(!QueryFilters.parse("#type app", now: spNow).allowsFiles, "#type app はファイルを探さない")
    // 日付
    let today = day("2026-11-19 00:00")
    has("#date today", ["kMDItemLastUsedDate >= \(isoUTC(today))", "kMDItemContentModificationDate >= \(isoUTC(today))",
                        "kMDItemDateAdded >= \(isoUTC(today))", "kMDItemContentCreationDate >= \(isoUTC(today))"])
    has("#date 7d", ["kMDItemLastUsedDate >= \(isoUTC(day("2026-11-12 00:00")))"])
    let yEnd = isoUTC(today - 1)
    has("#date yesterday", ["(kMDItemContentModificationDate <= \(yEnd) || kMDItemContentModificationDate != *)",
                            "(kMDItemLastUsedDate <= \(yEnd) || kMDItemLastUsedDate != *)"])   // 件数も一番新しい日で数える
    has("#modified 2026-11", ["kMDItemContentModificationDate >= \(isoUTC(day("2026-11-01 00:00")))"], not: ["kMDItemLastUsedDate", "DateAdded"])
    has("#created 2025", ["kMDItemContentCreationDate >= \(isoUTC(day("2025-01-01 00:00")))", "<= \(isoUTC(day("2026-01-01 00:00") - 1))"],
        not: ["ContentModificationDate", "!= *"])
    has("#date 11-14..11-16", [">= \(isoUTC(day("2026-11-14 00:00")))", "<= \(isoUTC(day("2026-11-17 00:00") - 1))"])
    // 場所
    ok(req("#path ~/Desktop").scopes == [NSHomeDirectory() + "/Desktop"], "#path ~/Desktop は範囲に")
    ok(!qs("#path ~/Desktop").contains("Desktop"), "#path は問い合わせの文に入れない")
    ok(req("#path /tmp").scopes == ["/private/tmp"], "#path /tmp は実際のパス（/private/tmp）")
    ok(req("#path 仕事").pathNames == ["仕事"] && req("#path 仕事").scopes.isEmpty, "#path 名前 はフォルダを引いて範囲にする")
    ok(req("請求書").scopes.isEmpty, "範囲の無い入力は Mac 全域")
    // 組み合わせ
    has("#kind pdf #date 7d 請求", ["com.adobe.pdf", "kMDItemLastUsedDate >=", "*請求*\"cd"])
    let rk = SpotlightSearch.nameStrengthForTest("請求書_2024", words: ["請求書", "2024"]), r1 = SpotlightSearch.nameStrengthForTest("請求書_控え", words: ["請求書", "2024"])
    ok(rk > r1 && r1 > 0, "当たった言葉が多いほど上（\(rk) > \(r1)）")
    ok(qs("#kind pdf #date 7d 請求").components(separatedBy: " && ").count >= 3, "違うコマンドどうしは「かつ」")
    has("#type d #name 仕事", ["public.folder", "*仕事*\"cd"])
    has("#ext swift #path ~/Project 請求", ["*.swift\"c", "*請求*"])
    ok(req("#ext swift #path ~/Project").scopes == [NSHomeDirectory() + "/Project"], "#ext と #path ~/ の組み合わせ")
    ok(SpotlightSearch.queryString(SpotlightSearch.Request()) == "kMDItemContentTypeTree == \"public.item\"", "条件が無ければ全部の物")
    // #with / #near（解析は「#」の担当。値の位置）
    let w = req("#with ~/Documents/a.pdf")
    ok(w.withAnchor == NSHomeDirectory() + "/Documents/a.pdf", "#with の値（\(w.withAnchor ?? "nil")）")
    let t0 = day("2026-11-19 10:00")
    let ws = SpotlightSearch.queryString(w, withTime: t0)
    ok(ws.contains("kMDItemLastUsedDate >= \(isoUTC(t0 - 1800))") && ws.contains("kMDItemLastUsedDate <= \(isoUTC(t0 + 1800))"),
       "#with は X を使った時刻の前後 30 分（\(ws)）")
    let wk = req("#with 見積書 #kind pdf")
    ok(wk.withAnchor == "見積書" && wk.families == ["pdf"], "#with 名前 と #kind の組み合わせ")
    let n = req("#near ~/Project/raiden/README.md #ext swift")
    ok(n.nearAnchor == NSHomeDirectory() + "/Project/raiden/README.md" && n.exts == ["swift"], "#near と #ext の組み合わせ（\(n.nearAnchor ?? "nil")）")
    let nn = req("#near raiden #name Engine")
    ok(nn.nearAnchor == "raiden" && nn.names == ["engine"], "#near 名前 と #name の組み合わせ")
    // 「#」の無い言い方（QueryIntent → 条件）
    let ss = req("先週のスクショ")
    ok(ss.families == ["screenshot"] && ss.dates.count == 1 && ss.words.isEmpty, "先週のスクショ → スクショ・先週（\(ss.families) \(ss.words)）")
    let pdf = req("去年の請求書のPDF")
    ok(pdf.families == ["pdf"] && pdf.dates.first?.1.contains(day("2025-06-01 00:00")) == true, "去年の…PDF → PDF・去年（\(pdf.words)）")
    ok(req("請求書が入ってるフォルダ").types == ["d"], "〜フォルダ → フォルダだけ")
    let dl = req("昨日ダウンロードしたPDF")
    ok(dl.download && SpotlightSearch.queryString(dl).contains("kMDItemWhereFroms"), "ダウンロード → kMDItemWhereFroms")
    let rel = req("見積書と同じ日に撮った写真")
    ok(rel.withAnchor != nil, "「A と同じ日の B」は #with A（\(rel.withAnchor ?? "nil")・\(rel.words)）")

    print("== #near のプロジェクトの根（~/Project の実物を読むだけ）")
    let p = NSHomeDirectory() + "/Project"
    let roots: [(String, String)] = [
        (p + "/raiden/app/Sources/RaidenCore/Engine.swift", p + "/raiden"),                   // .git
        (p + "/raiden/app/Sources", p + "/raiden"),                                             // フォルダから
        (p + "/sao-rpg/unity/Assets/Scenes/VillageSample.unity", p + "/sao-rpg/unity"),         // Unity（Assets と ProjectSettings）
        (p + "/digitalarchi-iplot/GCodeView_Unity/Assets/DefaultVolumeProfile.asset", p + "/digitalarchi-iplot/GCodeView_Unity"),  // 内側の Unity が先
        (p + "/kobako-story/rules/objects.json", p + "/kobako-story"),                          // pyproject.toml
        (p + "/te/recipes/finder-downloads.json", p + "/te"),                                   // .git と pyproject.toml
    ]
    for (x, want) in roots where FileManager.default.fileExists(atPath: x) {
        let got = SpotlightSearch.projectRoot(of: x)
        ok(got == want, "根 \(x) → \(got)（正解 \(want)）")
    }
    ok(SpotlightSearch.projectRoot(of: NSHomeDirectory() + "/Documents/raiden-none.pdf") == NSHomeDirectory() + "/Documents",
       "見つからなければ親フォルダ（~ の package.json は見ない）")
    ok(SpotlightSearch.projectRoot(of: "/private/tmp/raiden-none/a.txt") == "/private/tmp/raiden-none", "/ まで上がったら止めて親フォルダ")

    print("== 除外・種類・「選んだ」記録")
    let s = SpotlightSearch(exclude: RaidenSettings().exclude)
    let h = NSHomeDirectory()
    ok(s.excluded(h + "/Library/Caches/a.txt"), "~/Library は除外（初期値）")
    ok(s.excluded(h + "/Project/x/node_modules/a/b.js"), "除外の名前（node_modules）の中")
    ok(s.excluded("/Applications/Foo.app/Contents/Info.plist"), ".app の中")
    ok(s.excluded(h + "/Documents/a.photoslibrary/x.jpg"), "パッケージ（.photoslibrary）の中")
    ok(s.excluded(h + "/.config/a.txt"), "隠しフォルダの中")
    ok(s.excluded(h + "/Project/x/app.log"), "除外の名前（*.log）")
    ok(!s.excluded(h + "/Documents/仕事/請求書.pdf"), "普通のファイルは除外しない")
    let e = SpotlightSearch.entryForTest(["kMDItemPath": h + "/Movies/a.avi", "kMDItemContentType": "public.avi",
                                          "kMDItemContentTypeTree": ["public.avi", "public.movie", "public.item"]])
    ok(e?.families.contains("movie") == true, "UTI からも種類（.avi は movie）")
    let d = SpotlightSearch.entryForTest(["kMDItemPath": h + "/Documents/仕事", "kMDItemContentType": "public.folder"])
    ok(d?.isDir == true && d?.families == ["folder"], "public.folder はフォルダ")
    let ex = [("先週の見積書", "/x/見積書.pdf", Float(1)), ("音楽", "/x/a.mp3", Float(3))]
    ok((SpotlightSearch.exampleScores("先週の見積書", ex)["/x/見積書.pdf"] ?? 0) > 0.3, "同じ言い方の記録は加点")
    ok(SpotlightSearch.exampleScores("請求書", ex).isEmpty, "遠い言い方には加点しない")

    let fsrc = SpotlightFilterSource(search: s)
    ok(fsrc.counts(.kind, values: ["pdf"], within: QueryFilters.parse("#with ~/a.pdf ", now: spNow), now: spNow) == nil, "#with が付いていれば件数は数えない")
    ok(fsrc.counts(.near, values: ["~/a"], within: QueryFilters.parse("", now: spNow), now: spNow) == nil, "#near の値は数えない")

    print("確かめ \(spChecks - spFail)/\(spChecks)")
    exit(spFail == 0 ? 0 : 1)
}

/// いくつかの入力で Mac 全域に問い合わせた時間（3 回の中央と最大）
func runSpotlightBench() throws {
    guard let sp = opt("--file-store"), sp != Store.defaultURL.path else { print("--file-store <scratch の新しいファイル> を渡してください"); return }
    let e = Engine(store: try Store(url: URL(fileURLWithPath: sp)), exclude: RaidenSettings().exclude)
    let recent = e.spotlight.recent(limit: 5)
    let t0 = Date()
    let r20 = e.spotlight.recent(limit: 20)
    print(String(format: "最近使ったファイル・フォルダ 20 件 %.0fms（1 件目 %@）", Date().timeIntervalSince(t0) * 1000,
                 (r20.first?.name ?? "-")))
    let w = recent.first.map { "#with \($0.path)" } ?? "#with README.md"
    let inputs = ["請求書", "README", "Engine", "見積", "#kind pdf 請求", "#kind image #date 7d", "#ext swift #name Engine",
                  "#date today", "先週のスクショ", "#near ~/Project/raiden/README.md #ext swift", w, "#path Desktop #kind pdf",
                  "あのとき作った音声入力のやつ", "unity"]
    print("| 入力 | 1 回（中央 / 最大） | Spotlight から受け取った件数 | 出した件数 | 1 位 |")
    print("|---|---|---|---|---|")
    for q in inputs {
        var ms: [Double] = []
        var j: Judged<FileResult>?
        for _ in 0..<3 {
            let t = Date()
            j = e.searchFilesJudged(q, limit: 9)
            ms.append(Date().timeIntervalSince(t) * 1000)
        }
        let shown = q.hasPrefix("#with /") ? "#with（最近使った 1 件）" : q
        print(String(format: "| %@ | %.0fms / %.0fms | %d | %d | %@ |", shown, med(ms), ms.max() ?? 0, j?.signals.fetched ?? 0,
                     j?.results.count ?? 0, j?.results.first.map { $0.file.isDir ? "（フォルダ）" : "（ファイル）" } ?? "（0 件）"))
    }
    // 取り消し: 広い問い合わせを別の列で始め、10ms 後に止める
    let sem = DispatchSemaphore(value: 0)
    var cancelled = false
    var tEnd = Date()
    let tStart = Date()
    DispatchQueue.global().async {
        let r = e.spotlight.search("#date 1y", filters: QueryFilters.parse("#date 1y"), limit: 9)
        cancelled = r.cancelled; tEnd = Date(); sem.signal()
    }
    usleep(10_000)
    let tc = Date()
    e.cancelFiles()
    sem.wait()
    print(String(format: "取り消し: 始めてから %.0fms で止め、%.0fms で戻った（止まった %@）", tc.timeIntervalSince(tStart) * 1000,
                 tEnd.timeIntervalSince(tc) * 1000, cancelled ? "はい" : "いいえ（先に終わった）"))
    // 値の候補の件数（SpotlightFilterSource。1 回目は nil で裏で数え、届いたら onUpdate）
    let src = SpotlightFilterSource(search: SpotlightSearch(exclude: RaidenSettings().exclude))
    let done = DispatchSemaphore(value: 0)
    var updates = 0
    let vals = ["pdf", "image", "movie", "doc", "xls", "ppt", "md", "code"]
    src.onUpdate = { updates += 1; if updates == vals.count { done.signal() } }
    let tv = Date()
    let first = src.counts(.kind, values: vals, within: QueryFilters.parse("#date 7d "), now: Date())
    _ = done.wait(timeout: .now() + 20)
    let tw = Date().timeIntervalSince(tv) * 1000
    let second = src.counts(.kind, values: vals, within: QueryFilters.parse("#date 7d "), now: Date()) ?? [:]
    print(String(format: "#kind の値 8 つの件数（#date 7d の中で）: 1 回目 %@、裏で数え終わるまで %.0fms、2 回目（覚えた件数）%@", first == nil ? "nil（件数なしで出す）" : "あり", tw,
                 vals.map { "\($0) \(second[$0].map(String.init) ?? "-")" }.joined(separator: "・")))
    src.refreshRecent()
    usleep(500_000)
    print("最近使ったフォルダ（#path の候補）\(src.recentFolders(limit: 5).count) 件・ファイル（#with #near の候補）\(src.recentFiles(limit: 10).count) 件")
    print(String(format: "メモリ footprint %.0fMB", physFootprintMB()))
}

/// 起動（DB を開く・いつも開くアプリ・アプリ一覧・記録）から検索できるまで
func runBootBench() throws {
    guard let sp = opt("--file-store"), sp != Store.defaultURL.path else { print("--file-store <scratch の新しいファイル> を渡してください"); return }
    let fp0 = physFootprintMB()
    let t0 = Date()
    let store = try Store(url: URL(fileURLWithPath: sp))
    let tStore = Date()
    let e = Engine(store: store, exclude: RaidenSettings().exclude)
    let opens = OpenWithIndex.build(exclude: RaidenSettings().exclude)
    let tOpens = Date()
    e.setApps(AppCatalog.collect(opens: opens))
    let tApps = Date()
    e.loadExamples()
    let tReady = Date()
    _ = e.searchJudged("PDFを見るやつ")
    let tApp1 = Date()
    _ = e.searchFilesJudged("請求書")
    let tFile1 = Date()
    func ms(_ a: Date, _ b: Date) -> String { String(format: "%.0fms", b.timeIntervalSince(a) * 1000) }
    print("| 段 | 時間 |")
    print("|---|---|")
    print("| DB を開く（片付けを含む。消した点 \(store.migratedFiles)） | \(ms(t0, tStore)) |")
    print("| いつも開くアプリ（~/Documents・Downloads・Desktop を Spotlight で \(opens.byFile.count) 件） | \(ms(tStore, tOpens)) |")
    print("| アプリ一覧と辞書（\(e.apps.count) 個） | \(ms(tOpens, tApps)) |")
    print("| 記録を読む（\(e.examples.count) 件） | \(ms(tApps, tReady)) |")
    print("| 起動から検索できるまで | \(ms(t0, tReady)) |")
    print("| アプリの検索 1 回目 | \(ms(tReady, tApp1)) |")
    print("| ファイルの検索 1 回目（Spotlight） | \(ms(tApp1, tFile1)) |")
    print(String(format: "メモリ footprint 起動前 %.0fMB → 検索できる状態 %.0fMB（resident %.0fMB）", fp0, physFootprintMB(), residentMB()))
}
