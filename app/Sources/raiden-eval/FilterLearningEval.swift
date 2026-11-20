// 入力欄の「#」の覚える・保存・言葉からの候補・#with #near・辞書・#alias の確かめ（raiden-eval --test-filters から呼ぶ。モデル不要）
import Foundation
import RaidenCore

private var failures = 0
private var checks = 0
private func expect(_ ok: Bool, _ msg: @autoclosure () -> String) {
    checks += 1
    if !ok { failures += 1; print("  NG " + msg()) }
}
/// 2026-11-19 12:00（日本時間）を基準にする（FilterEval.swift と同じ）
private let testNow: Date = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    return f.date(from: "2026-11-19 12:00")!
}()

// MARK: - 覚える・保存・言葉からの候補・#with #near・辞書・#alias

/// 件数を数えられない口（Spotlight の答えがまだ届いていないとき）
private struct NoCountSource: FilterSource {
    var appCount: Int { 0 }
    var files: [String] = []
    func recentFiles(limit: Int) -> [String] { Array(files.prefix(limit)) }
}

/// 件数だけ決まった数を返す口（差し替えの確かめ）
private struct FixedSource: FilterSource {
    var appCount: Int { 7 }
    func counts(_ cmd: QueryFilters.Command, values: [String], within others: QueryFilters, now: Date) -> [String: Int]? {
        Dictionary(uniqueKeysWithValues: values.map { ($0, $0 == "7d" ? 42 : 1) })
    }
    func topExtensions(within others: QueryFilters, limit: Int) -> [(String, Int)]? { [("heic", 9), ("pdf", 3)] }
}

private func logEntry(_ q: String, chosen: String? = nil, kind: String = "file", dismissed: Bool = false, notFound: Bool = false,
                      daysAgo: Double = 1) -> SearchLogEntry {
    let t = Int(testNow.timeIntervalSince1970 - daysAgo * 86400)
    var e = SearchLogEntry(ts: t, query: q, edits: [], candidates: [], dismissed: dismissed || chosen == nil, notFound: notFound, ms: 1)
    if let c = chosen { e.chosenKind = kind; e.chosenKey = c; e.chosenName = (c as NSString).lastPathComponent; e.chosenRank = 1; e.dismissed = false }
    return e
}

/// 戻り値は（項目数, 失敗の数）
func runFilterLearningTests(ctx: FilterContext) -> (Int, Int) {
    let home = NSHomeDirectory()
    func p(_ q: String) -> QueryFilters { QueryFilters.parse(q, now: testNow) }
    func pal(_ t: String, committed: [String] = [], ctx: FilterSource? = nil, memory: FilterMemory = .empty) -> FilterCompletion.Palette? {
        FilterCompletion.palette(for: t, committed: committed, context: ctx, memory: memory, now: testNow)
    }
    SavedFilters.set([])
    PhraseDictionary.set([])

    print("== 候補の並び（件数を出す口の差し替え）")
    let nc = NoCountSource(files: [home + "/Documents/見積書_サンプル.pdf", home + "/Project/raiden/README.md"])
    let e0 = pal("#ext ", ctx: nc)?.items ?? []
    expect(!e0.isEmpty && e0.allSatisfy { $0.count == nil } && e0.contains { $0.insert == "pdf" }, "件数を出せない口でも #ext の候補だけ出す \(e0.map(\.insert))")
    let k0 = pal("#kind ", ctx: nc)?.items ?? []
    expect(k0.count >= 10 && k0.allSatisfy { $0.count == nil }, "件数を出せない口では #kind を全部出す（\(k0.count) 件）")
    let d0 = pal("#date ", ctx: nc)?.items ?? []
    expect(d0.first?.insert == "today" && d0.first?.count == nil, "件数なしの #date は決まった順")
    let e1 = pal("#ext ", ctx: ctx)?.items ?? []
    expect(e1.first?.insert == "png" && e1.first?.count == 2, "#ext は手元に多い拡張子の順 \(e1.map { "\($0.insert) \($0.count ?? -1)" })")
    let fx = FixedSource()
    expect(pal("#date ", ctx: fx)?.items.first { $0.insert == "7d" }?.count == 42, "差し替えた口の件数を使う")
    expect(pal("#ext ", ctx: fx)?.items.first?.insert == "heic", "差し替えた口の拡張子の並び \(pal("#ext ", ctx: fx)?.items.map(\.insert) ?? [])")
    expect(pal("#type ", ctx: fx)?.items.first { $0.insert == "app" }?.count == 7, "#type app はアプリの数")
    let pf = pal("#path ")?.items.map(\.detail) ?? []
    expect(pf == ["~/Desktop", "~/Documents", "~/Downloads"], "一覧も記録も無ければ決まった場所 \(pf)")
    var mExt = FilterMemory()
    mExt.values[.ext] = ["md": 3]
    expect(pal("#ext ", ctx: ctx, memory: mExt)?.items.first?.insert == "md", "よく使った拡張子を先頭に")
    expect(pal("#ext ", memory: mExt)?.items.first?.insert == "md", "口が無くてもよく使った拡張子を先頭に")
    var mPath = FilterMemory()
    mPath.folders = [home + "/Documents/Obsidian Vault", home + "/Downloads/請求"]
    let pp = pal("#path ", ctx: ctx, memory: mPath)?.items ?? []
    expect(pp.first?.title == "Obsidian Vault" && pp.first?.badge == "よく使う", "#path はよく使う場所を先頭に \(pp.map(\.title))")
    expect(pp.last?.title == "請求" && pp.last?.count == 0, "ほかの条件の中で 0 件の場所は下に回す")
    expect(pp.contains { $0.title == "Desktop" && ($0.count ?? 0) > 0 }, "#path の中身の多いフォルダは件数つき")
    expect(FilterCompletion.next(p("#kind ss"), context: nil).isEmpty, "口も記録も無ければ次のコマンドは出さない")

    print("== よく使う組み合わせ（検索の記録から）")
    let log = [
        logEntry("#ext pdf #path Downloads 請求", chosen: home + "/Downloads/請求書.pdf"),
        logEntry("#ext pdf #path Downloads 見積", chosen: home + "/Downloads/見積書.pdf", daysAgo: 2),
        logEntry("#path Downloads #ext pdf", chosen: home + "/Downloads/領収書.pdf", daysAgo: 3),
        logEntry("#e pdf #in Downloads", chosen: home + "/Downloads/a.pdf", daysAgo: 4),
        logEntry("#kind ss", dismissed: true),
        logEntry("#date 7d #kind image", chosen: home + "/Desktop/x.png", daysAgo: 200),
        logEntry("黒い画面", dismissed: true, daysAgo: 1),
        logEntry("ふわふわのやつ", notFound: true, daysAgo: 2),
        logEntry("黒い画面", dismissed: true, daysAgo: 5),
    ]
    let mem = FilterMemory.build(from: log, now: testNow)
    expect(mem.combos.first?.commands == ["#ext pdf", "#path Downloads"], "組み合わせを数える（順と別名をそろえる）\(mem.combos.map(\.text))")
    expect(mem.combos.first?.count == 4, "同じ組み合わせは 4 回 \(mem.combos.first?.count ?? -1)")
    expect(!mem.combos.contains { $0.text == "#kind ss" }, "選ばずに閉じた 1 回だけの組み合わせは出さない")
    expect(!mem.combos.contains { $0.text.contains("#kind image") }, "古い記録（200 日前）は点数が下がって出さない")
    expect((mem.values[.ext]?["pdf"] ?? 0) > 3, "値ごとの点数 pdf \(mem.values[.ext]?["pdf"] ?? 0)")
    expect(mem.folders.first == "Downloads", "よく使う場所 \(mem.folders.prefix(3))")
    expect(mem.folders.contains(home + "/Downloads"), "選んだファイルの親フォルダもよく使う場所")
    expect(mem.files.first == home + "/Downloads/請求書.pdf" && mem.files.count == 5, "最近選んだファイル \(mem.files.count)")
    expect(mem.missed == ["黒い画面", "ふわふわのやつ"], "選ばずに閉じた言い方（重ねない）\(mem.missed)")
    let pc = pal("#", memory: mem)?.items ?? []
    expect(pc.first?.title == "#ext pdf #path Downloads" && pc.first?.commits == ["#ext pdf", "#path Downloads"], "「#」の直後の先頭によく使う組み合わせ \(pc.prefix(2).map(\.title))")
    expect(pc.first?.badge == "よく使う", "組み合わせの行に印")
    if let pa = pal("請求 #", memory: mem), let it = pa.items.first {
        let r = FilterCompletion.accept(it, palette: pa, text: "請求 #")
        expect(r.commits == ["#ext pdf", "#path Downloads"] && r.text == "請求 " && r.commit == nil, "組み合わせを決めるとまとめてチップ \(r)")
    }
    let rest = pal("#", committed: ["#ext pdf"], memory: mem)?.items.first
    expect(rest?.commits == ["#path Downloads"], "チップを含む組み合わせは残りだけ \(rest?.title ?? "nil")")
    expect(pal("#", committed: ["#kind ss"], memory: mem)?.items.first?.badge != "よく使う", "チップを含まない組み合わせは出さない")
    expect(pal("#ex", memory: mem)?.items.first?.title == "#ext", "打ちかけ（#ex）では組み合わせを出さずコマンド")
    let nx = FilterCompletion.next(p("#ext pdf"), context: ctx, memory: mem, now: testNow)
    expect(nx.first?.commits == ["#path Downloads"], "#ext pdf の後に組み合わせの続き \(nx.map(\.title))")
    let up = pal("#ext ", ctx: ctx, memory: mem)?.items.first?.insert
    expect(up == "pdf", "記録でよく使う値（pdf）を値の候補の先頭に \(up ?? "nil")")
    // Store を通す（一時ファイル。本物の raiden.sqlite には触らない）
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("raiden-filter-test-\(getpid()).sqlite")
    if let st = try? Store(url: tmp) {
        for e in log { st.logSearch(e) }
        let m2 = FilterMemory.build(from: st.searchLog(limit: 100), now: testNow)
        expect(m2.combos.map(\.text) == mem.combos.map(\.text) && m2.missed == mem.missed, "search_log に書いて読み直しても同じ \(m2.combos.map(\.text))")
    } else { expect(false, "一時の Store を作れない") }
    for suf in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp.path + suf) }

    print("== 名前を付けて保存した絞り込み")
    SavedFilters.set([SavedFilter(name: "仕事のPDF", commands: ["#ext pdf", "#path 仕事"])])
    let sv = p("#仕事のPDF 請求")
    expect(sv.exts == ["pdf"] && sv.paths == ["仕事"] && sv.text == "請求" && sv.notes.isEmpty, "#仕事のPDF を中身に広げる \(sv.exts) \(sv.paths) 「\(sv.text)」")
    expect(p("#仕事のpdf").exts == ["pdf"], "大文字小文字はそろえる")
    expect(p("＃仕事のPDF").paths == ["仕事"], "全角の「＃」でも呼べる")
    expect(p("#仕事の").notes.isEmpty, "打ちかけ（#仕事の）は知らせない")
    expect(p("#仕事のXLS").notes == ["#仕事のxls は使えません"], "無い名前は知らせる \(p("#仕事のXLS").notes)")
    expect(FilterCompletion.extractCommitted("#仕事のPDF ", now: testNow)?.commands == ["#ext pdf", "#path 仕事"], "空白まで打つと中身のチップに")
    let ps = pal("#仕")?.items.first
    expect(ps?.title == "#仕事のPDF" && ps?.commits == ["#ext pdf", "#path 仕事"] && ps?.badge == "保存", "#仕 で保存した名前の候補")
    expect(pal("#")?.items.contains { $0.title == "#仕事のPDF" } == true, "「#」の一覧に保存した名前")
    expect(pal("#", committed: ["#ext pdf", "#path 仕事"])?.items.contains { $0.title == "#仕事のPDF" } == false, "もう全部付いている名前は出さない")
    for (n, ok) in [("仕事のPDF", true), ("kind", false), ("in", false), ("保存", false), ("仕事 PDF", false), ("", false), ("1月", false), ("a-b", false), ("#週報", true)] {
        expect((SavedFilter.problem(name: n) == nil) == ok, "名前「\(n)」は\(ok ? "使える" : "使えない") \(SavedFilter.problem(name: n) ?? "")")
    }
    let save = pal("#保存 週報", committed: ["#ext md", "#date 7d"])
    expect(save?.mode == .save && save?.items.first?.insert == "週報" && save?.items.first?.commits == ["#ext md", "#date 7d"], "#保存 名前 で保存の行")
    expect(pal("#save 週報", committed: ["#ext md"])?.mode == .save, "#save でも同じ")
    expect(pal("#保存 ", committed: [])?.items.first?.insert == "", "チップが無ければ保存できない")
    expect(pal("#保存 kind", committed: ["#ext md"])?.items.first?.insert == "", "コマンドの名前では保存できない")
    expect(pal("#保存 仕事のPDF", committed: ["#ext md"])?.items.first?.title.contains("上書き") == true, "同じ名前は上書きと出す")
    let sp = p("#保存 週報")
    expect(sp.notes.isEmpty && sp.saving == "週報" && !sp.isActive && sp.text.isEmpty, "#保存 は絞り込みにしない")
    expect(pal("#", committed: ["#ext md"])?.items.contains { $0.title == "#保存" } == true, "チップがあれば一覧に #保存")
    expect(pal("#")?.items.contains { $0.title == "#保存" } == false, "チップが無ければ #保存 は出さない")
    expect(FilterCompletion.extractCommitted("#保存 週報 ", now: testNow) == nil, "#保存 の名前はチップにしない")
    if let pa = save, let it = pa.items.first {
        expect(FilterCompletion.accept(it, palette: pa, text: "#保存 週報").text == "", "保存したら入力欄から外す")
    }

    print("== 「#」を打たない言葉からの候補")
    SavedFilters.set([])
    func sg(_ t: String, _ c: [String] = [], _ m: FilterMemory = .empty) -> [String] { FilterSuggest.suggest(t, committed: c, memory: m).map(\.title) }
    expect(sg("pdf") == ["#ext pdf"], "pdf → #ext pdf \(sg("pdf"))")
    expect(sg("先週の請求書") == ["#date lastweek"], "先週 → #date lastweek \(sg("先週の請求書"))")
    expect(sg("画像") == ["#kind image"], "画像 → #kind image")
    expect(sg("ダウンロードのpdf") == ["#ext pdf", "#path Downloads"], "後ろの言葉から \(sg("ダウンロードのpdf"))")
    expect(sg("pdfs").isEmpty && sg("Cpdf").isEmpty, "英数字の途中は当てない")
    expect(sg("#ext pdf").isEmpty, "「#」のトークンの中は見ない")
    expect(sg("先週", ["#date 7d"]).isEmpty, "同じコマンドがチップにあれば出さない")
    expect(sg("スクリーンショット 昨日") == ["#date yesterday", "#kind ss"], "スクリーンショット・昨日 \(sg("スクリーンショット 昨日"))")
    expect(sg("今月 先週").count == 1, "同じコマンドの候補は 1 つ \(sg("今月 先週"))")
    expect(sg("昨日 画像 pdf ダウンロード").count == FilterSuggest.limit, "一度に出すのは \(FilterSuggest.limit) つまで")
    expect(sg("PDF").first == "#ext pdf", "大文字でも当てる")
    expect(sg("見積書").isEmpty, "関係ない言葉では出さない")
    var mf = FilterMemory()
    mf.folders = [home + "/Documents/仕事"]
    expect(sg("仕事の資料", [], mf) == ["#path 仕事"], "よく使う場所の名前 \(sg("仕事の資料", [], mf))")
    if let s1 = FilterSuggest.suggest("先週の請求書").first {
        expect(FilterSuggest.accept(s1, text: "先週の請求書") == "請求書", "決めたら言葉と「の」を外す「\(FilterSuggest.accept(s1, text: "先週の請求書"))」")
        expect(s1.commands == ["#date lastweek"] && s1.word == "先週", "決めるとチップにするコマンド")
    }
    if let s2 = FilterSuggest.suggest("昨日から pdf").first(where: { $0.title.hasPrefix("#date") }) {
        expect(FilterSuggest.accept(s2, text: "昨日から pdf") == "pdf", "「から」も外す")
    }
    expect(!p("先週の pdf").isActive && !p("先週の pdf").hasSyntax, "候補を出すだけで勝手には絞らない")
    SavedFilters.set([SavedFilter(name: "仕事のPDF", commands: ["#ext pdf", "#path 仕事"])])
    let sgs = FilterSuggest.suggest("仕事のPDF")
    expect(sgs.count == 1 && sgs.first?.commands == ["#ext pdf", "#path 仕事"], "保存した名前が入力にあれば候補（pdf は重ねない）\(sgs.map(\.title))")
    SavedFilters.set([])

    print("== #with・#near")
    let w = p("#with ~/Documents/見積書.pdf 請求")
    expect(w.withPath == home + "/Documents/見積書.pdf" && w.text == "請求" && w.isActive && w.hasRelation, "#with のパス \(w.withPath ?? "nil")")
    expect(w.chips.first?.label == "一緒に使った: 見積書.pdf" && w.chips.first?.command == .with, "#with のチップ \(w.chips.map(\.label))")
    expect(p("#w ~/a.pdf").withPath == home + "/a.pdf" && p("#一緒 ~/a.pdf").withPath == home + "/a.pdf", "#w・#一緒")
    let n = p("#near ~/Project/raiden/README.md")
    expect(n.nearPath == home + "/Project/raiden/README.md" && n.chips.first?.label == "同じプロジェクト: README.md", "#near のパスとチップ \(n.chips.map(\.label))")
    expect(p("#nr ~/x/y.md").nearPath == home + "/x/y.md" && p("#近く ~/x/y.md").nearPath == home + "/x/y.md", "#nr・#近く")
    expect(p("#with ~/a.pdf #with ~/b.pdf").withPath == home + "/b.pdf", "#with を 2 回書いたら後の方")
    expect(p("#with \"~/Documents/My File.pdf\"").withPath == home + "/Documents/My File.pdf", "空白を含むパスは \"\" で囲む")
    expect(p("#with").pending == "with" && p("#with").notes.isEmpty, "値の無い #with は打ちかけ")
    expect(p("#near ~/a").notes.isEmpty && p("#near ~/a").parsed.first?.ok == true, "#near の解析結果")
    expect(!p("#with ~/a.pdf").allowsApps, "#with はアプリを出さない")
    expect(p("#type app #near ~/a").notes.first?.contains("#near") == true, "アプリと #near は一緒に使えない")
    expect(p("#with ~/a.pdf").without(.with).withPath == nil && !p("#with ~/a.pdf").without(.with).isActive, "without(.with)")
    expect(p("#with ~/a.pdf").matches(FileEntry(path: home + "/zzz.txt")), "手元の matches では #with を見ない（土台の側で絞る）")
    expect(FilterCompletion.extractCommitted("#with ~/a.pdf ", now: testNow)?.commands == ["#with ~/a.pdf"], "空白まで打つと #with のチップ")
    let wv = pal("#with ", ctx: nc, memory: mem)?.items ?? []
    expect(wv.first?.title == "請求書.pdf" && wv.contains { $0.title == "README.md" }, "#with の候補は最近選んだ物と口の最近の物 \(wv.map(\.title))")
    expect(wv.allSatisfy { $0.count == nil }, "#with の候補に件数は出さない")
    let wv2 = pal("#near 見積", ctx: nc, memory: mem)?.items.map(\.title) ?? []
    expect(wv2 == ["見積書.pdf", "見積書_サンプル.pdf"], "名前の一部で絞る \(wv2)")
    expect(pal("#with ", memory: mem)?.items.first?.insert == "~/Downloads/請求書.pdf", "決めると ~/ のパスが入る")
    expect(FilterCompletion.commands(matching: "").contains { $0.title == "#with" } && FilterCompletion.commands(matching: "ne").first?.title == "#near", "一覧に #with・#near")

    print("== 辞書")
    let dict = [
        DictEntry(phrase: "黒い画面", target: .app, key: "/System/Applications/Utilities/Terminal.app", name: "ターミナル"),
        DictEntry(phrase: "ネット見るやつ", target: .app, key: "/Applications/Safari.app", name: "Safari"),
        DictEntry(phrase: "仕事のPDF", target: .filter, key: "#ext pdf #in ~/Documents/仕事"),
        DictEntry(phrase: "見積", target: .file, key: "~/Documents/見積書.pdf"),
        DictEntry(phrase: "画面", target: .app, key: "/System/Applications/Preview.app", name: "プレビュー"),
        DictEntry(phrase: "net", target: .app, key: "/Applications/Safari.app", name: "Safari"),
    ]
    func dm(_ q: String) -> [String] { PhraseDictionary.matches(q, in: dict).map(\.name) }
    expect(dm("黒い画面") == ["ターミナル", "プレビュー"], "黒い画面 → ターミナル（長い言い方を先に）\(dm("黒い画面"))")
    expect(dm("黒い画面ひらく").first == "ターミナル", "入力に含まれれば当てる")
    expect(dm("くろいがめん").isEmpty, "言い方が違えば当てない")
    expect(dm("#type app 黒い画面").first == "ターミナル", "コマンドは抜いて見る")
    expect(dm("ネット 見るやつ").first == "Safari", "空白は見ない")
    expect(dm("ＮＥＴ").first == "Safari", "全角・大文字もそろえる")
    expect(dm("").isEmpty && dm("#ext pdf").isEmpty, "言葉が無ければ当てない")
    expect(dict[2].commands == ["#ext pdf", "#path ~/Documents/仕事"] && dict[2].name == "#ext pdf #in ~/Documents/仕事", "条件の行のコマンド \(dict[2].commands)")
    expect(dict[3].key == home + "/Documents/見積書.pdf" && dict[3].name == "見積書.pdf", "ファイルの行は ~ を広げる")
    expect(DictEntry(phrase: "", target: .app, key: "x").problem != nil, "言い方が空なら足せない")
    expect(DictEntry(phrase: "a", target: .filter, key: "#size 3").problem != nil, "読めない条件は足せない")
    expect(DictEntry(phrase: "a", target: .file, key: "見積書.pdf").problem != nil, "ファイルは絶対パスだけ")
    expect(dict.allSatisfy { $0.problem == nil }, "正しい行は足せる")
    let add1 = PhraseDictionary.adding(DictEntry(phrase: "メモ", target: .app, key: "/System/Applications/Notes.app", name: "メモ"), to: dict)
    expect(!add1.replaced && add1.list.count == dict.count + 1, "新しい言い方は足す")
    let add2 = PhraseDictionary.adding(DictEntry(phrase: "黒い画面", target: .file, key: "/tmp/x", name: "x"), to: dict)
    expect(add2.replaced && add2.list.count == dict.count && add2.list[0].name == "x", "同じ言い方は置き換える")
    PhraseDictionary.set(dict)
    let ds = FilterSuggest.suggest("仕事のPDFを探す")
    expect(ds.first?.commands == ["#ext pdf", "#path ~/Documents/仕事"] && ds.first?.label == "辞書", "辞書の条件は言葉からの候補に出す \(ds.map(\.title))")
    expect(!p("仕事のPDFを探す").isActive, "辞書の条件も勝手には絞らない")
    var rs = RaidenSettings()
    rs.dictionary = dict
    rs.savedFilters = [SavedFilter(name: "週報", commands: ["#ext md"])]
    if let d = try? JSONEncoder().encode(rs), let back = try? JSONDecoder().decode(RaidenSettings.self, from: d) {
        expect(back.dictionary == dict && back.savedFilters == rs.savedFilters, "settings.json に書いて読める")
    } else { expect(false, "settings の読み書き") }
    expect((try? JSONDecoder().decode(RaidenSettings.self, from: Data("{}".utf8)))?.dictionary.isEmpty == true, "古い settings.json は辞書が空")

    print("== #alias（辞書に足す）")
    let al = p("#alias 黒い画面")
    expect(al.pending == "alias" && al.aliasing == "黒い画面" && al.notes.isEmpty && !al.isActive && al.text.isEmpty, "#alias 言い方 は絞り込みにしない")
    expect(p("#dict ねこ").aliasing == "ねこ" && p("#辞書 ねこ").aliasing == "ねこ", "#dict・#辞書")
    expect(p("#al").notes.isEmpty && p("#辞").notes.isEmpty, "打ちかけ（#al）は知らせない")
    let a0 = pal("#alias ", memory: mem)
    expect(a0?.mode == .alias && a0?.items.map(\.insert) == ["黒い画面", "ふわふわのやつ"], "#alias の直後は選ばずに閉じた言い方 \(a0?.items.map(\.insert) ?? [])")
    expect(pal("#alias ")?.items.first?.insert == "", "記録が無ければ案内だけ")
    let a1 = pal("#alias ねこ", memory: mem)
    expect(a1?.items.first?.insert == "ねこ" && a1?.items.first?.title.contains("どれに") == true, "打った言い方の行 \(a1?.items.first?.title ?? "")")
    expect(pal("#alias ふわ", memory: mem)?.items.map(\.insert) == ["ふわ", "ふわふわのやつ"], "打ちかけで記録の言い方を絞る")
    expect(pal("#alias 黒い画面")?.items.first?.detail.contains("置き換え") == true, "辞書にある言い方は置き換えると出す")
    if let pa = a1, let it = pa.items.first {
        let r = FilterCompletion.accept(it, palette: pa, text: "#alias ねこ")
        expect(r.text == "" && r.commit == nil && r.commits.isEmpty, "決めると入力欄から外す（行き先を選ぶ状態は入力欄の側）")
    }
    expect(pal("#a")?.items.contains { $0.title == "#alias" } == true, "#a の一覧に #alias")
    if let pa = pal("#ali"), let it = pa.items.first(where: { $0.title == "#alias" }) {
        expect(FilterCompletion.accept(it, palette: pa, text: "#ali").text == "#alias ", "一覧から #alias を選ぶと「#alias 」")
    }
    expect(FilterCompletion.extractCommitted("#alias 黒い画面 ", now: testNow) == nil, "#alias の言い方はチップにしない")
    PhraseDictionary.set([])
    return (checks, failures)
}
