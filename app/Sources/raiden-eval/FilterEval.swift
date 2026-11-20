// 入力欄の絞り込みコマンド（QueryFilters / FilterCompletion）の確かめ。
//
//   raiden-eval --test-filters                 解析・一覧・値の候補の単体の確かめ
//   raiden-eval --filters [--now 2026-11-19] --file-store <scratch の新しいファイル>
//       ~/Library/Application Support/Raiden/evals/filters.json の答え合わせ（Engine.searchFilesJudged を通す）
//       [{"q": 入力, "mode": "all" | "top" | "none", "allowed": [~/ からのパス], "gold": [~/ からのパス]}]
//         all:  残りの文が空。当てはまる物（allowed）が全部出て、それ以外が 1 件も出ないこと
//         top:  言葉つき。出た物がすべて allowed の中（混ざり 0）で、gold が 1 位・3 位以内か
//         none: 当てはまる物が 0 件。候補が空で noMatch が立つこと
import Foundation
import RaidenCore

private var failures = 0
private var checks = 0
private func expect(_ ok: Bool, _ msg: @autoclosure () -> String) {
    checks += 1
    if !ok { failures += 1; print("  NG " + msg()) }
}

/// 2026-11-19 12:00（日本時間）を基準にする
private let testNow: Date = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    return f.date(from: "2026-11-19 12:00")!
}()
private func ts(_ s: String) -> Int {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    return Int(f.date(from: s)!.timeIntervalSince1970)
}

func runFilterTests() {
    print("== 解析（基準日 2026-11-19）")
    func p(_ q: String) -> QueryFilters { QueryFilters.parse(q, now: testNow) }
    func inRange(_ f: QueryFilters, _ c: QueryFilters.Command, _ day: String) -> Bool { f.dates[c]?.range.contains(ts(day)) ?? false }

    // コマンドの無い入力は今までどおり
    for q in ["PDFを見るやつ", "kobako-devlog", "2026-11 の請求書", "1/2", "and/or", "C-3PO", "-1 と -2", "C# の本", "#1 と #2", "-kind pdf", "昨日のスクショ"] {
        let f = p(q)
        expect(!f.hasSyntax && f.text == q && !f.isActive, "コマンド無し「\(q)」→ hasSyntax \(f.hasSyntax) text「\(f.text)」")
    }
    var f = p("#date 7d #kind ss 請求書")
    expect(f.text == "請求書", "残りの文 「\(f.text)」")
    expect(f.kinds == ["screenshot"], "種類 \(f.kinds)")
    expect(inRange(f, .date, "2026-11-12 09:00") && inRange(f, .date, "2026-11-19 23:00") && !inRange(f, .date, "2026-11-11 23:00"),
           "直近7日の範囲")
    expect(f.chips.map(\.label) == ["期間: 直近7日", "種類: スクショ"], "チップ \(f.chips.map(\.label))")
    f = p("請求書 #kind pdf #date 2026-09")
    expect(f.text == "請求書" && f.kinds == ["pdf"] && inRange(f, .date, "2026-09-30 23:59") && !inRange(f, .date, "2026-10-01 00:00"), "末尾のコマンド")
    f = p("#k pdf #k doc"); expect(f.kinds == ["pdf", "doc"] && f.chips.map(\.label) == ["種類: PDF・Word・文書"], "#k を 2 回は「または」 \(f.chips.map(\.label))")
    f = p("#kind pdf,docx"); expect(f.kinds == ["pdf"] && f.kindExts == ["docx"] && f.chips.map(\.label) == ["種類: PDF・.docx"], "#kind の種類でない値は拡張子 \(f.chips.map(\.label))")
    f = p("#ext pdf,docx #e key"); expect(f.exts == ["pdf", "docx", "key"] && f.chips.map(\.label) == ["拡張子: .pdf・.docx・.key"], "#ext のカンマと 2 回")
    f = p("#date today #date yesterday"); expect(inRange(f, .date, "2026-11-18 10:00") && !inRange(f, .date, "2026-11-19 10:00"), "#date 2 回は後で上書き")
    f = p("#date 11-14..11-16"); expect(inRange(f, .date, "2026-11-14 00:00") && inRange(f, .date, "2026-11-16 23:59") && !inRange(f, .date, "2026-11-17 00:00") && !inRange(f, .date, "2026-11-13 23:59"), "範囲")
    f = p("#date 2026-11-14"); expect(inRange(f, .date, "2026-11-14 12:00") && !inRange(f, .date, "2026-11-15 00:00"), "その日")
    f = p("#date 11月14日"); expect(inRange(f, .date, "2026-11-14 12:00") && !inRange(f, .date, "2026-11-15 00:00"), "11月14日")
    f = p("#date 2026年11月14日"); expect(inRange(f, .date, "2026-11-14 12:00") && !inRange(f, .date, "2026-11-13 23:59"), "2026年11月14日")
    f = p("#date 11月"); expect(inRange(f, .date, "2026-11-01 00:00") && inRange(f, .date, "2026-11-30 23:59") && !inRange(f, .date, "2026-12-01 00:00"), "11月")
    f = p("#date 12月"); expect(inRange(f, .date, "2025-12-10 12:00"), "まだ来ていない月は去年")
    f = p("#date 2026年11月"); expect(inRange(f, .date, "2026-11-30 12:00") && !inRange(f, .date, "2026-10-31 12:00"), "2026年11月")
    f = p("#date 11月1日〜11月14日"); expect(inRange(f, .date, "2026-11-01 00:00") && inRange(f, .date, "2026-11-14 23:59") && !inRange(f, .date, "2026-11-15 00:00"), "日本語の範囲")
    f = p("#date 7日"); expect(inRange(f, .date, "2026-11-12 12:00") && f.chips.first?.label.contains("直近7日") == true, "7日 は今までどおり直近7日")
    let days = FilterCompletion.palette(for: "#date ", now: testNow)?.items.filter { $0.symbol == "calendar" } ?? []
    expect(days.first?.title == "11-17（火）" && days.first?.insert == "11-17" && days.count == 12, "1 日ずつの候補 \(days.first?.title ?? "")…\(days.count) 件")
    expect(FilterCompletion.palette(for: "#date 11-1", now: testNow)?.items.first?.insert == "11-1", "打ちかけの日付が先頭")
    f = p("#date 12-25"); expect(inRange(f, .date, "2025-12-25 12:00"), "まだ来ていない月日は去年")
    f = p("#date 先週"); expect(inRange(f, .date, "2026-11-10 12:00") && !inRange(f, .date, "2026-11-17 12:00"), "先週（月曜はじまりでなくても 11/10 は先週）")
    f = p("#date 今月"); expect(inRange(f, .date, "2026-11-01 00:00") && !inRange(f, .date, "2026-10-31 23:59"), "今月")
    f = p("#date 先月"); expect(inRange(f, .date, "2026-10-15 00:00") && !inRange(f, .date, "2026-11-01 00:00"), "先月")
    f = p("#date 2w"); expect(inRange(f, .date, "2026-11-05 01:00") && !inRange(f, .date, "2026-11-04 23:00"), "2w")
    f = p("#date 3m"); expect(inRange(f, .date, "2026-08-19 12:00") && !inRange(f, .date, "2026-08-18 12:00"), "3m")
    f = p("#date 1y"); expect(inRange(f, .date, "2025-11-20 12:00"), "1y")
    f = p("#m 昨日 #c 2026"); expect(inRange(f, .modified, "2026-11-18 12:00") && inRange(f, .created, "2026-03-01 00:00"), "#m #c")
    f = p("#type d #path Desktop"); expect(f.types == ["d"] && f.paths == ["Desktop"] && f.chips.map(\.label) == ["フォルダだけ", "場所: Desktop"], "#type d #path")
    f = p("#t f,d"); expect(f.types == ["f", "d"], "#t f,d")
    f = p("#in ~/Desktop #p \"Obsidian Vault\" メモ"); expect(f.paths == ["~/Desktop", "Obsidian Vault"] && f.text == "メモ", "#in と引用符 \(f.paths) 「\(f.text)」")
    f = p("#name 請求 #n 見積"); expect(f.names == ["請求", "見積"], "#name")
    f = p("#種類 pdf #日付 今日 #場所 Desktop #名前 請求"); expect(f.kinds == ["pdf"] && f.dates[.date] != nil && f.paths == ["Desktop"] && f.names == ["請求"], "日本語の名前")
    f = p("#type app #date 7d"); expect(!f.allowsApps && f.notes.contains { $0.contains("一緒に使えません") }, "アプリと #date はぶつかる \(f.notes)")
    f = p("#type app"); expect(f.allowsApps && !f.allowsFiles, "#type app はアプリだけ")
    f = p("#type d #date 7d"); expect(!f.allowsApps && f.allowsFiles && f.notes.isEmpty, "#type d と #date は使える")
    f = p("#size 3m 請求書"); expect(f.notes == ["#size は使えません"] && !f.isActive && f.text == "3m 請求書", "知らないコマンド \(f.notes) 「\(f.text)」")
    f = p("#date あした 請求書"); expect(f.notes == ["#date の「あした」は読めません"] && !f.isActive && f.text == "請求書", "読めない値 \(f.notes)")
    // 打っている途中は知らせない・絞らない
    for q in ["#", "請求書 #", "＃", "#da", "#date", "請求書 #date", "#date 2026-", "#kind sc"] {
        let g = p(q)
        expect(g.notes.isEmpty && !g.isActive && g.pending != nil, "打ちかけ「\(q)」→ notes \(g.notes) pending \(g.pending ?? "nil")")
    }
    expect(p("請求書 #").text == "請求書", "打ちかけの「#」は残りの文に入れない")
    expect(p("#date 7d").isActive, "最後の値でも読めれば効く")
    expect(p("#help ").notes == ["#help は使えません"] && p("#h 請求書").notes == ["#h は使えません"], "#help は無い（知らないコマンド）")

    // 当てはまるか
    let home = NSHomeDirectory()
    let ss = FileEntry(path: home + "/Desktop/スクリーンショット 2026-11-15 10.00.00.png", mtime: ts("2026-11-15 10:00"))
    let pdf = FileEntry(path: home + "/Documents/仕事/請求書_9月.pdf", mtime: ts("2026-09-10 10:00"), created: ts("2026-09-01 10:00"))
    let dir = FileEntry(path: home + "/Documents/仕事", isDir: true, mtime: ts("2026-11-18 10:00"))
    let md = FileEntry(path: home + "/Documents/Obsidian Vault/メモ.md", mtime: ts("2026-11-19 09:00"))
    expect(p("#kind ss").matches(ss) && !p("#kind ss").matches(pdf), "スクショ")
    expect(p("#kind image").matches(ss), "スクショは画像でも当たり")
    expect(p("#kind md").matches(md) && p("#ext md").matches(md) && !p("#ext md").matches(pdf), "md")
    expect(p("#type d").matches(dir) && !p("#type d").matches(pdf) && !p("#type f").matches(dir), "#type")
    expect(p("#kind folder").matches(dir) && !p("#kind pdf").matches(dir), "#kind folder")
    expect(p("#path 仕事").matches(pdf) && !p("#path 仕事").matches(dir), "#path 名前は下だけ（フォルダ自身は入らない）")
    expect(p("#path ~/Documents").matches(pdf) && !p("#path ~/Desktop").matches(pdf) && p("#path ~/Desktop").matches(ss), "#path ~/")
    expect(p("#path documents/仕事").matches(pdf), "#path パスの一部")
    expect(p("#path \"Obsidian Vault\"").matches(md) && p("#path obsidian").matches(md), "#path 空白入り・大文字小文字")
    expect(p("#name 請求").matches(pdf) && !p("#name 請求").matches(md), "#name")
    expect(p("#date 2026-09").matches(pdf) && !p("#date 2026-11").matches(pdf), "#date は変更日でも")
    let redone = FileEntry(path: NSHomeDirectory() + "/Desktop/上書き.png", mtime: ts("2026-11-19 10:00"), created: ts("2026-11-18 10:00"), added: ts("2026-11-18 10:00"))
    expect(p("#date today").matches(redone) && !p("#date yesterday").matches(redone), "#date は最後に触った日（昨日作って今日上書きした物は今日だけ）")
    expect(p("#created yesterday").matches(redone) && !p("#modified yesterday").matches(redone), "作成日・変更日で探せば昨日も出る")
    expect(FilterCompletion.countText(10_000) == "1万以上" && FilterCompletion.countText(9_999) == "9999", "上限まで数えたら 1万以上")
    expect(p("#created 2026-09-01").matches(pdf) && !p("#modified 2026-09-01").matches(pdf), "#created / #modified")
    expect(p("#kind pdf #path 仕事 #date 2026-09").matches(pdf) && !p("#kind pdf #path 仕事 #date 2026-10").matches(pdf), "かつ")
    expect(p("#path Desktop #path 仕事").matches(pdf) && p("#path Desktop #path 仕事").matches(ss), "#path 2 回は「または」")

    print("== 一覧と値の候補")
    func pal(_ t: String, committed: [String] = [], ctx: FilterContext? = nil) -> FilterCompletion.Palette? {
        FilterCompletion.palette(for: t, committed: committed, context: ctx, now: testNow)
    }
    expect(pal("#")?.mode == .commands && pal("#")?.items.filter { $0.commits.isEmpty && $0.title != "#alias" && $0.title != "#clip" }.count == FilterCompletion.commandItems.count
           && pal("#")?.items.last?.title == "#alias", "「#」で全部の一覧（#clip と、最後に #alias）")
    expect(pal("請求書 #")?.mode == .commands, "空白の直後の「#」")
    expect(pal("＃")?.mode == .commands && pal("＃da")?.items.map(\.title) == ["#date"], "全角の「＃」でも一覧")
    expect(pal("C#") == nil && pal("#1") == nil, "「C#」「#1」は一覧を出さない")
    for t in ["kobako-", "2026-", "請求書-", "-1", "PDFを見るやつ", "1/2"] { expect(pal(t) == nil, "一覧を出さない「\(t)」") }
    expect(pal("#da")?.items.map(\.title) == ["#date"], "#da → #date: \(pal("#da")?.items.map(\.title) ?? [])")
    expect(pal("#k")?.items.map(\.title) == ["#kind"], "#k → #kind")
    expect(pal("#t")?.items.map(\.title) == ["#type"], "#t → #type: \(pal("#t")?.items.map(\.title) ?? [])")
    expect(pal("#種")?.items.map(\.title) == ["#kind"], "#種 → #kind")
    expect(pal("#場")?.items.map(\.title) == ["#path"], "#場 → #path")
    expect(pal("#in")?.items.map(\.title) == ["#path"], "#in → #path")
    expect(pal("#size") == nil, "知らない名前は一覧なし")
    expect(pal("#kind")?.mode == .commands, "「#kind」（空白前）はまだコマンドの一覧")
    expect(pal("#kind ")?.mode == .values(.kind), "「#kind 」で種類の候補")
    expect(pal("#date ")?.items.prefix(3).map(\.title) == ["今日", "昨日", "直近7日"], "#date の候補 \(pal("#date ")?.items.prefix(3).map(\.title) ?? [])")
    expect(pal("#date 7")?.items.first?.insert == "7d", "#date 7 → 7d")
    expect(pal("#date 2026-11")?.items.first?.title == "2026年11月", "#date 2026-11（手で打った日付）")
    expect(pal("#kind sc")?.items.first?.insert == "ss", "#kind sc → ss")
    expect(pal("#kind pdf,do")?.items.first?.insert == "pdf,doc", "#kind pdf,do → pdf,doc: \(pal("#kind pdf,do")?.items.map(\.insert) ?? [])")
    expect(pal("#type ")?.items.map(\.insert) == ["f", "d", "app"], "#type の候補")
    expect(pal("#name ") == nil, "#name は候補なし")
    expect(pal("#date 7d ") == nil, "値の後に空白を打ったら閉じる")
    expect(pal("#help") == nil && pal("#help ") == nil, "#help で一覧は出さない")
    // 決める
    if let p1 = pal("請求書 #da") {
        let r = FilterCompletion.accept(p1.items[0], palette: p1, text: "請求書 #da")
        expect(r.text == "請求書 #date " && r.commit == nil, "コマンドを決める → 「\(r.text)」")
    }
    if let p2 = pal("請求書 #date 7") {
        let r = FilterCompletion.accept(p2.items[0], palette: p2, text: "請求書 #date 7")
        expect(r.text == "請求書 " && r.commit == "#date 7d", "値を決める → 「\(r.text)」 \(r.commit ?? "nil")")
    }
    let ex = FilterCompletion.extractCommitted("#date 2026-11-14 請求書 #kind pdf ", now: testNow)
    expect(ex?.commands == ["#date 2026-11-14", "#kind pdf"] && ex?.text == "請求書 ", "打ち終えたコマンドをチップに \(String(describing: ex))")
    expect(FilterCompletion.extractCommitted("#date 2026-1", now: testNow) == nil, "打ちかけはチップにしない")
    expect(FilterCompletion.extractCommitted("#date あした ", now: testNow) == nil, "読めない値はチップにしない")

    // #type の別名（前の版の #app #folder #file）
    for (q, t) in [("#app", "app"), ("#folder", "d"), ("#file", "f"), ("#t #app", "app"), ("#type #folder", "d"), ("#t #app s", "app"), ("#app ", "app")] {
        let g = p(q)
        expect(g.types == [t] && g.notes.isEmpty, "別名「\(q)」→ \(g.types) \(g.notes)")
    }
    for q in ["#ap", "#t #ap", "#t #fol"] {
        let g = p(q)
        expect(g.notes.isEmpty, "打ちかけ「\(q)」は知らせない \(g.notes)")
    }
    expect(p("＃kind pdf").kinds == ["pdf"] && p("＃t ＃app").types == ["app"] && p("＃種類 pdf 請求書").text == "請求書", "全角の「＃」")
    expect(p("#t #app sa").text == "sa", "「#t #app sa」の残りは sa")
    expect(pal("#ap")?.items.first?.title == "#type", "#ap → #type の行")
    expect(FilterCompletion.commands(matching: "").first { $0.title == "#type" }?.alias.contains("#app") == true, "一覧の #type に別名 #app")
    expect(pal("#t #ap")?.mode == .values(.type) && pal("#t #ap")?.items.first?.insert == "app", "「#t #ap」は #type の値の候補")
    expect(pal("#t #fol")?.items.first?.insert == "d", "「#t #fol」→ d")
    if let p3 = pal("#t #ap") {
        let r = FilterCompletion.accept(p3.items[0], palette: p3, text: "#t #ap")
        expect(r.text == "" && r.commit == "#type app", "「#t #ap」で決める → 「\(r.text)」 \(r.commit ?? "nil")")
    }
    expect(FilterCompletion.extractCommitted("#t #app ", now: testNow)?.commands == ["#type app"], "「#t #app 」をチップに")
    expect(FilterCompletion.extractCommitted("#folder ", now: testNow)?.commands == ["#type d"], "「#folder 」をチップに")

    // 件数（見本の一覧）
    let sample = [ss, pdf, dir, md,
                  FileEntry(path: home + "/Desktop/スクリーンショット 2026-11-19 08.00.00.png", mtime: ts("2026-11-19 08:00")),
                  FileEntry(path: home + "/Downloads/写真.jpg", mtime: ts("2026-11-01 08:00"))]
    let ctx = FilterContext(files: sample, appCount: 3)
    let dv = pal("#date ", ctx: ctx)?.items ?? []
    func c(_ items: [FilterCompletion.Item], _ ins: String) -> Int? { items.first { $0.insert == ins }?.count }
    expect(c(dv, "today") == 2 && c(dv, "7d") == 4, "#date の件数 今日 \(c(dv, "today") ?? -1) 直近7日 \(c(dv, "7d") ?? -1)")
    expect(dv.last?.count == 0, "0 件は下に回す")
    let dvss = pal("#date ", committed: ["#kind ss"], ctx: ctx)?.items ?? []
    expect(c(dvss, "today") == 1 && c(dvss, "7d") == 2, "#kind ss の中の #date の件数 \(c(dvss, "today") ?? -1) / \(c(dvss, "7d") ?? -1)")
    let kv = pal("#kind ", ctx: ctx)?.items ?? []
    expect(kv.first?.insert == "image" && kv.allSatisfy { ($0.count ?? 0) > 0 }, "#kind は手元にある種類だけを多い順 \(kv.map { "\($0.insert) \($0.count ?? -1)" })")
    // 件数と結果が食い違わない
    for t in ["#date 7d", "#kind ss", "#kind image #date today", "#path Desktop", "#type d"] {
        let n = ctx.indices(p(t)).count
        let parts = t.split(separator: " ")
        let cmd = String(parts[parts.count - 2]), v = String(parts[parts.count - 1])
        let base = parts.count > 2 ? [parts.prefix(parts.count - 2).joined(separator: " ")] : []
        let items = pal(cmd + " ", committed: base, ctx: ctx)?.items ?? []
        let got = cmd == "#path" ? items.first { $0.title == v }?.count : c(items, v)
        expect(got == n, "件数「\(t)」 候補 \(got ?? -1) / 結果 \(n)")
    }
    // 次に付けそうなコマンド
    let nx = FilterCompletion.next(p("#kind ss"), context: ctx, now: testNow)
    expect(nx.first?.insert == "#date today", "#kind ss の後は #date \(nx.map(\.insert))")
    let nx2 = FilterCompletion.next(p("#date 7d"), context: ctx, now: testNow)
    expect(nx2.first?.insert.hasPrefix("#kind") == true, "#date の後は #kind \(nx2.map(\.insert))")

    let (lc, lf) = runFilterLearningTests(ctx: ctx)
    checks += lc; failures += lf
    print("（うち 覚える・保存・言葉からの候補・#with #near・辞書・#alias の確かめ \(lc - lf)/\(lc)）")
    print("確かめ \(checks - failures)/\(checks)")

    exit(failures == 0 ? 0 : 1)
}

struct FilterQ: Decodable { let q: String; let mode: String; let allowed: [String]?; let gold: [String]? }

func runFilterEval(appEngine: Engine) throws {
    let evalDir = opt("--evals") ?? RaidenPaths.support.appendingPathComponent("evals").path
    let qs = try JSONDecoder().decode([FilterQ].self, from: Data(contentsOf: URL(fileURLWithPath: evalDir + "/filters.json")))
    guard let sp = opt("--file-store"), sp != Store.defaultURL.path else { print("--file-store <scratch の新しいファイル> を渡してください"); return }
    let e = Engine(store: try Store(url: URL(fileURLWithPath: sp)), exclude: RaidenSettings().exclude)
    let fm = FileManager.default
    print("== 絞り込みの答え合わせ（\(qs.count) 問、基準日 \(opt("--now") ?? "2026-11-19")、Spotlight）")
    var pure = 0, full = 0, nAll = 0, h1 = 0, h3 = 0, nTop = 0, okNone = 0, nNone = 0
    var mixed = 0
    var appsLeak = 0
    for q in qs {
        let allowed = Set((q.allowed ?? []).map(abs).filter { fm.fileExists(atPath: $0) })
        let gold = Set((q.gold ?? []).map(abs).filter { fm.fileExists(atPath: $0) })
        let lim = q.mode == "all" ? allowed.count + 10 : 20
        let t = Date()
        let j = e.searchFilesJudged(q.q, limit: lim, now: evalNow)
        let ms = Date().timeIntervalSince(t) * 1000
        let got = j.results.map(\.file.path)
        let extra = got.filter { !allowed.contains($0) }
        // ファイルの条件が付いているときはアプリを出さない
        let aj = appEngine.searchJudged(q.q, limit: 9)
        if !aj.results.isEmpty { appsLeak += 1 }
        let short = { (p: String) in (p as NSString).lastPathComponent }
        switch q.mode {
        case "none":
            nNone += 1
            let ok = got.isEmpty && j.noMatch
            if ok { okNone += 1 }
            print("  \(ok ? "○" : "×") [0件] \(q.q) → \(got.count) 件 noMatch \(j.noMatch)  \(String(format: "%.0f", ms))ms")
        case "all":
            nAll += 1
            let missing = allowed.subtracting(got)
            if extra.isEmpty { pure += 1 } else { mixed += extra.count }
            if extra.isEmpty && missing.isEmpty { full += 1 }
            print("  \(extra.isEmpty && missing.isEmpty ? "○" : "×") [一覧] \(q.q) → \(got.count) 件（正解 \(allowed.count)）混ざり \(extra.count) 漏れ \(missing.count)  \(String(format: "%.0f", ms))ms"
                  + (extra.isEmpty ? "" : "  混ざり例: " + extra.prefix(3).map(short).joined(separator: " | "))
                  + (missing.isEmpty ? "" : "  漏れ例: " + missing.prefix(3).map(short).joined(separator: " | ")))
            // 新しい順か
            let keys = j.results.map { max($0.file.lastUsed, $0.file.mtime) }
            if zip(keys, keys.dropFirst()).contains(where: { $0 < $1 }) { print("     ※ 新しい順になっていない") }
        default:
            nTop += 1
            if extra.isEmpty { pure += 1 } else { mixed += extra.count }
            let a = got.first.map(gold.contains) ?? false
            let b = got.prefix(3).contains(where: gold.contains)
            if a { h1 += 1 }
            if b { h3 += 1 }
            print("  \(a ? "○" : b ? "△" : "×") [言葉] \(q.q) → \(got.prefix(3).map(short).joined(separator: " | "))（\(got.count) 件）混ざり \(extra.count)  \(String(format: "%.0f", ms))ms")
        }
    }
    print("混ざり 0 の問題 \(pure)/\(nAll + nTop)（混ざった件数 \(mixed)）  一覧が完全に一致 \(full)/\(nAll)  言葉つき 1位 \(h1)/\(nTop) 3位以内 \(h3)/\(nTop)  0件 \(okNone)/\(nNone)  アプリが出た問題 \(appsLeak)")
}
