import Foundation
import RaidenCore

/// 入手元（#src）と、候補が多いときの絞り込みの問い（Recall.split）の確かめ。手元のファイルは使わない
func runRecallTests() -> (Int, Int) {
    var checks = 0, failures = 0
    func expect(_ ok: Bool, _ msg: @autoclosure () -> String) {
        checks += 1
        if !ok { failures += 1; print("  NG " + msg()) }
    }
    print("== 入手元（#src）と絞り込みの問い")
    let now = Date(timeIntervalSince1970: 1_795_000_000)   // 2026-11 の中ごろ
    let t = Int(now.timeIntervalSince1970)
    let home = NSHomeDirectory()
    func file(_ path: String, days: Int, dl: Bool = false, mail: Bool = false) -> FileEntry {
        let name = (path as NSString).lastPathComponent
        return FileEntry(path: path, name: name, parentName: "", isDir: false, kind: "", families: name.hasSuffix(".pdf") ? ["pdf"] : ["text"],
                         size: 1, mtime: t - days * 86400, created: t - days * 86400, added: 0, lastUsed: 0, usedDays: [],
                         downloaded: dl || mail, fromMail: mail)
    }

    // #src の読み取り
    let f = QueryFilters.parse("#src dl 見積", now: now)
    expect(f.sources == ["dl"] && f.text == "見積" && f.chips.first?.label == "入手元: ダウンロード", "#src dl のチップ \(f.chips.map(\.label))")
    expect(QueryFilters.parse("#入手元 メール添付", now: now).sources == ["mail"], "#入手元 メール添付")
    expect(QueryFilters.parse("#src mine,dl", now: now).sources == ["mine", "dl"], "#src mine,dl は「または」")
    expect(QueryFilters.parse("#src xyz 見積", now: now).notes.first?.contains("読めません") == true, "#src の読めない値は知らせる")
    expect(!QueryFilters.parse("#src dl", now: now).allowsApps, "#src が付いたらアプリは出さない")
    let dlF = QueryFilters.parse("#src dl", now: now), mineF = QueryFilters.parse("#src mine", now: now), mailF = QueryFilters.parse("#src mail", now: now)
    let a = file(home + "/Downloads/a.pdf", days: 1, dl: true), m = file(home + "/Downloads/m.pdf", days: 1, mail: true), o = file(home + "/Documents/o.md", days: 1)
    expect(dlF.matches(a) && !dlF.matches(m) && !dlF.matches(o), "#src dl はダウンロードだけ（メール添付は別）")
    expect(mailF.matches(m) && !mailF.matches(a), "#src mail はメール添付だけ")
    expect(mineF.matches(o) && !mineF.matches(a) && !mineF.matches(m), "#src mine は自分で作成した物だけ")
    expect(FilterCompletion.palette(for: "#src ")?.items.map(\.insert) == ["dl", "mail", "mine"], "#src の値の一覧")
    expect(FilterCompletion.commands(matching: "").first?.title == "時期" && FilterCompletion.commands(matching: "").first?.insert == "#date",
           "「#」の一覧の先頭は 時期（#date）")
    expect(FilterCompletion.commands(matching: "入手").first?.insert == "#src", "#入手 → #src")

    // 絞り込みの問い
    let root: (String) -> String = { ($0 as NSString).deletingLastPathComponent }
    let few = (0..<10).map { file(home + "/d/x\($0).pdf", days: $0) }
    expect(Recall.split(few, filters: nil, now: now, projectRoot: root) == nil, "候補が少なければ問いは出さない")
    // 時期がよく割れる: 今週 10・先月 30・去年 20（種類は全部 PDF、場所は 1 か所、入手元は全部自分）
    var es: [FileEntry] = []
    es += (0..<10).map { file(home + "/w/a\($0).pdf", days: 1 + $0 % 2) }
    es += (0..<30).map { file(home + "/w/b\($0).pdf", days: 35 + $0 % 5) }
    es += (0..<20).map { file(home + "/w/c\($0).pdf", days: 400 + $0) }
    let sp = Recall.split(es, filters: nil, now: now, projectRoot: root)
    expect(sp?.title == "時期で絞り込む" && sp?.total == 60, "時期で割る \(sp?.title ?? "nil") \(sp?.options.map { "\($0.label) \($0.count)" } ?? [])")
    expect(sp?.options.contains { $0.command == "#date 先月" && $0.count == 30 } == true, "先月 30 件の選び先")
    expect(sp.map { $0.options.count >= 2 && $0.options.count <= 4 } == true, "選び先は 2〜4 個")
    // 付いている切り口は聞かない（#date があれば時期は聞かない → 場所も入手元も割れないので出さない）
    expect(Recall.split(es, filters: QueryFilters.parse("#date 1y", now: now), now: now, projectRoot: root)?.title != "時期で絞り込む",
           "#date が付いていれば時期は聞かない")
    // 入手元でよく割れる: 同じ日・同じ種類で、ダウンロード 20・自分 20
    var ss: [FileEntry] = (0..<20).map { file(home + "/s/d\($0).pdf", days: 3, dl: true) }
    ss += (0..<20).map { file(home + "/s/m\($0).pdf", days: 3) }
    let sp2 = Recall.split(ss, filters: nil, now: now, projectRoot: root)
    expect(sp2?.title == "入手元で絞り込む" && sp2?.options.map(\.command).sorted() == ["#src dl", "#src mine"], "入手元で割る \(sp2?.title ?? "nil")")
    // 場所で割る: 2 つのプロジェクトに半分ずつ（日付・種類・入手元は同じ）
    var ps: [FileEntry] = (0..<20).map { file(home + "/Project/aa/f\($0).md", days: 3) }
    ps += (0..<20).map { file(home + "/Project/bb/g\($0).md", days: 3) }
    let sp3 = Recall.split(ps, filters: nil, now: now, projectRoot: root)
    expect(sp3?.title == "場所で絞り込む" && sp3?.options.contains { $0.command == "#path ~/Project/aa" } == true, "場所で割る \(sp3?.options.map(\.command) ?? [])")
    // 最近の作業のまとまり: 45 分あいたら分ける、1 まとまり 4 行まで、合計 9 行まで
    func used(_ p: String, minAgo: Int) -> FileEntry {
        FileEntry(path: home + p, name: (p as NSString).lastPathComponent, parentName: "", isDir: false, kind: "", families: [], size: 1,
                  mtime: 0, created: 0, added: 0, lastUsed: t - minAgo * 60, usedDays: [], downloaded: false)
    }
    let rec = [used("/Project/aa/a1.swift", minAgo: 5), used("/Project/aa/a2.swift", minAgo: 20), used("/Project/aa/a3.md", minAgo: 50),
               used("/Project/bb/b1.png", minAgo: 200), used("/Project/bb/b2.png", minAgo: 210), used("/Applications/X.app", minAgo: 1)]
    let ses = Recall.sessions(rec, now: now, projectRoot: root)
    expect(ses.count == 2 && ses[0].items.count == 3 && ses[1].items.count == 2, "45 分あいたら別のまとまり \(ses.map { "\($0.title) \($0.items.count)" })")
    expect(ses.first?.title.hasPrefix("今日") == true && ses.first?.title.hasSuffix("· aa") == true, "まとまりの名前は日と場所 \(ses.first?.title ?? "")")
    expect(!ses.flatMap(\.items).contains { $0.name.hasSuffix(".app") }, "アプリは入れない")
    let many = (0..<20).map { used("/Project/cc/f\($0).txt", minAgo: $0 * 60) }
    expect(Recall.sessions(many, now: now, projectRoot: root).reduce(0) { $0 + $1.items.count } <= 9, "合計 9 行まで")
    print("確かめ \(checks - failures)/\(checks)")
    return (checks, failures)
}
