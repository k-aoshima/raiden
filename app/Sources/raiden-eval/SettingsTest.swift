import Foundation
import RaidenCore

/// 設定・除外・前の版の DB の片付け・選んだ／開いた記録・検索の記録・動作の記録の確かめ
/// （raiden-eval --settings-test --store <コピーした raiden.sqlite>）。
/// ユーザーのファイル・本物の settings.json・ログ・DB には触らない:
///   設定は一時フォルダの settings.json、ログは一時フォルダ、DB は --store で渡したコピー。
func runSettingsTest() throws {
    guard let sp = opt("--store") else { print("--store <コピーした raiden.sqlite> を渡してください"); return }
    guard sp != Store.defaultURL.path else { print("本物の raiden.sqlite は使えません。コピーを渡してください"); return }
    let fm = FileManager.default
    let pid = getpid()
    // 一時フォルダは /var → /private/var のリンクなので、実際のパスにしておく（一覧のパスは実際のパス）
    let tmp0 = fm.temporaryDirectory.appendingPathComponent("raiden-test-\(pid)", isDirectory: true)
    try fm.createDirectory(at: tmp0, withIntermediateDirectories: true)
    let tmp = URL(fileURLWithPath: ScanScope(roots: [tmp0.path]).roots[0], isDirectory: true)
    var fails = 0
    func check(_ label: String, _ ok: Bool) {
        print("  \(ok ? "OK  " : "失敗") \(label)")
        if !ok { fails += 1 }
    }

    // MARK: 設定の読み書き
    print("設定の読み書き（\(tmp.path)/settings.json）")
    let su = tmp.appendingPathComponent("settings.json")
    check("無いときは初期値", RaidenSettings.load(from: su) == RaidenSettings())
    check("除外するフォルダの初期値は ~/Library", RaidenSettings().excludeFolders == ["~/Library"]
          && RaidenSettings().exclude.excludesPath(NSHomeDirectory() + "/Library/Caches/x"))
    var s = RaidenSettings()
    s.excludeFolders = ["~/Documents/raiden-test-ex"]
    s.excludeNames.append("*.tmp")
    s.hotKey = .init(keyCode: 49, modifiers: 4096 | 2048, label: "⌃⌥Space")
    s.maxRows = 12; s.sectionOrder = .filesFirst; s.transparency = 0.3
    s.learn = false; s.logSearches = false; s.logDays = 30
    try s.save(to: su)
    let back = RaidenSettings.load(from: su)
    check("書いて読むと同じ", back == s)
    check("除外のフォルダは ~ を広げる", back.exclude.excludeDirs == [NSHomeDirectory() + "/Documents/raiden-test-ex"])
    let text = (try? String(contentsOf: su, encoding: .utf8)) ?? ""
    check("保存は ~/ の形", text.contains("\"~/Documents/raiden-test-ex\"") && !text.contains(NSHomeDirectory()))
    try "{ 壊れた json".write(to: su, atomically: true, encoding: .utf8)
    check("壊れていたら初期値", RaidenSettings.load(from: su) == RaidenSettings())
    try #"{"maxRows": "たくさん", "logDays": 7, "folders": [{"path": "~/Desktop", "enabled": true}], "transparency": 5, "unloadMinutes": 5}"#
        .write(to: su, atomically: true, encoding: .utf8)
    let part = RaidenSettings.load(from: su)
    check("読めない項目だけ初期値（maxRows 9・logDays 7・透明度は 0.9 まで。前の版の folders・unloadMinutes は読み捨てる）",
          part.maxRows == 9 && part.logDays == 7 && part.transparency == 0.9)
    check("前の版の settings.json（除外のフォルダの初期値を知らない）には ~/Library を足す", part.excludeFolders == ["~/Library"])
    var noLib = part
    noLib.excludeFolders = []
    try noLib.save(to: su)
    check("~/Library を外したら、読み直しても戻らない", RaidenSettings.load(from: su).excludeFolders.isEmpty)
    // 前の版の settings.json（knownExcludeDefaults が無い）: 増えた初期値だけを足し、ユーザーが消した前の初期値（Pods）は戻さない
    try #"{"excludeNames": ["node_modules", ".venv", "venv", "__pycache__", ".git", "DerivedData", "*.tmp"]}"#
        .write(to: su, atomically: true, encoding: .utf8)
    let mig = RaidenSettings.load(from: su)
    check("除外の初期値: 増えた分（build・dist・target・*.log）だけ足し、消した Pods は戻さない・足した物は残る",
          mig.excludeNames.contains("build") && mig.excludeNames.contains("dist") && mig.excludeNames.contains("target")
          && mig.excludeNames.contains("*.log") && !mig.excludeNames.contains("Pods") && mig.excludeNames.contains("*.tmp"))
    var mig2 = mig
    mig2.excludeNames.removeAll { $0 == "build" }
    try mig2.save(to: su)
    check("新しい初期値を消したら、読み直しても戻らない", !RaidenSettings.load(from: su).excludeNames.contains("build"))
    let sc = ScanScope(roots: ["~/x"], excludeDirs: ["~/x/skip"], excludeNames: ["node_modules", "*.tmp", "build?"])
    check("除外の名前（そのまま・* ・?・隠し・.app）",
          sc.excludesName("node_modules") && sc.excludesName("a.tmp") && sc.excludesName("build1") && !sc.excludesName("build10")
          && sc.excludesName(".DS_Store") && sc.excludesName("Foo.app") && !sc.excludesName("memo.txt"))
    check("除外のフォルダ（その中も・名前が前方一致なだけの隣は除かない）",
          sc.excludesPath(NSHomeDirectory() + "/x/skip/a") && !sc.excludesPath(NSHomeDirectory() + "/x/skipper"))

    // MARK: 前の版の DB の片付けと、選んだ・開いた記録
    print("データベース（\(sp) のコピー）")
    let before = (try? fm.attributesOfItem(atPath: sp)[.size] as? Int) ?? 0
    var t = Date()
    let store = try Store(url: URL(fileURLWithPath: sp))
    print(String(format: "  開く（前の版なら片付けて VACUUM）%.2fs  消したファイル・フォルダの点 %d  大きさ %.1fMB → %.1fMB", Date().timeIntervalSince(t),
                 store.migratedFiles, Double(before) / 1_048_576, Double((try? fm.attributesOfItem(atPath: sp)[.size] as? Int) ?? 0) / 1_048_576))
    check("片付けの印（meta files = spotlight1）", store.meta("files") == "spotlight1" && store.meta("file_scope") == nil && store.meta("fs_event_id") == nil)
    check("contains / co_time / opens の線は無い", store.edgeCount(kind: "contains") == 0 && store.edgeCount(kind: "co_time") == 0 && store.edgeCount(kind: "opens") == 0)
    t = Date()
    let again = try Store(url: URL(fileURLWithPath: sp))
    check(String(format: "2 回目は片付けない（%.2fs）", Date().timeIntervalSince(t)), again.migratedFiles == 0)
    let dA = tmp.appendingPathComponent("raiden-test-qx8-ペンギン.txt").path
    let dB = tmp.appendingPathComponent("raiden-test-qx8-フラミンゴ.txt").path
    let q = "raiden-test-qx8 ペンギンのメモ"
    store.recordFileChoice(query: q, path: dA, isDir: false, name: "p")
    check("選んだ記録（chose の線）が入る", store.fileExamples().contains { $0.0 == q && $0.1 == dA })
    check("覚えた例の一覧に出る", store.learnedExamples().contains { $0.query == q && $0.key == dA && $0.kind == "file" })
    let exs = SpotlightSearch.exampleScores("raiden-test-qx8 ペンギンのメモ帳", store.fileExamples())
    check("入力の文字が近ければ加点（記録の入力と 1 文字違い）", (exs[dA] ?? 0) > 0.3)
    check("遠い入力には加点しない", SpotlightSearch.exampleScores("カピバラ", store.fileExamples())[dA] == nil)
    store.recordOpenedTogether(path: dA, isDir: false)
    store.recordOpenedTogether(path: dB, isDir: false)
    store.recordOpenedTogether(path: dA, isDir: false)
    check("30 分以内に Raiden から開いた物どうしに co_used の線（両向き・重みは回数）",
          store.coUsed(dA)[dB] == 2 && store.coUsed(dB)[dA] == 2)
    store.deleteLearned(query: q, kind: "file", key: dA)
    check("覚えた例を 1 件消せる", !store.learnedExamples().contains { $0.query == q } && !store.fileExamples().contains { $0.0 == q })

    // MARK: 検索の記録
    print("検索の記録（search_log）")
    store.clearSearchLog()
    let now = Int(Date().timeIntervalSince1970)
    let cands = [SearchLogEntry.Candidate(kind: "app", key: "com.apple.Preview", name: "プレビュー", score: 1.2, section: "app"),
                 SearchLogEntry.Candidate(kind: "file", key: "/dummy/a.pdf", name: "a.pdf", score: 0.8, section: "file")]
    let edits = [SearchLogEntry.Edit(q: "p", t: 300), SearchLogEntry.Edit(q: "pdf", t: 700), SearchLogEntry.Edit(q: "PDFを見るやつ", t: 2100)]
    store.logSearch(SearchLogEntry(ts: now - 10, query: "PDFを見るやつ", edits: edits, candidates: cands, chosenKind: "file",
                                   chosenKey: "/dummy/a.pdf", chosenName: "a.pdf", chosenRank: 2, dismissed: false, notFound: false, ms: 23.5))
    store.logSearch(SearchLogEntry(ts: now - 5, query: "ふわふわのやつ", edits: [], candidates: cands, dismissed: true,
                                   notFound: true, notFoundApps: true, notFoundFiles: true, ms: 19))
    store.logSearch(SearchLogEntry(ts: now - 100 * 86400, query: "古い記録", edits: [], candidates: [], dismissed: true, notFound: false, ms: 10))
    let rows = store.searchLog(limit: 10)
    check("書いて読める（3 件・新しい順）", rows.map(\.query) == ["ふわふわのやつ", "PDFを見るやつ", "古い記録"])
    if let r = rows.first(where: { $0.query == "PDFを見るやつ" }) {
        check("中身が同じ（打ち直し・候補・選んだ物と順位・時間）",
              r.edits == edits && r.candidates == cands && r.chosenKey == "/dummy/a.pdf" && r.chosenRank == 2 && !r.dismissed && r.ms == 23.5)
    } else { check("中身が同じ", false) }
    let nf = store.searchLog(limit: 10, onlyNotFound: true)
    check("見つからなかった言い方だけ読める", nf.map(\.query) == ["ふわふわのやつ"] && nf[0].notFoundApps && nf[0].dismissed)
    store.markSearchLogTaught(id: nf[0].id, kind: "app", key: "com.apple.Preview", name: "プレビュー")
    check("正解を教えたら見つからなかった一覧から外れる", store.searchLog(limit: 10, onlyNotFound: true).isEmpty)
    let pruned = store.pruneSearchLog(days: 90)
    check("90 日より古い記録を消す（1 件）", pruned == 1 && store.searchLogCount() == 2)
    store.clearSearchLog()
    check("全部消す", store.searchLogCount() == 0)

    // MARK: 動作の記録
    print("動作の記録（raiden.log の回し方）")
    let ld = tmp.appendingPathComponent("logs", isDirectory: true)
    let log = RaidenLog(dir: ld, maxBytes: 2000, keep: 3, keepDays: 30)
    log.echo = false
    for i in 0..<200 { log.info("テストの行 \(i) " + String(repeating: "あ", count: 20)) }
    log.error("エラーの行")
    log.flush()
    let names = Set((try? fm.contentsOfDirectory(atPath: ld.path)) ?? [])
    check("raiden.log と raiden.1〜3.log がある・4 は無い（大きさで回して古いものは消す）",
          names.isSuperset(of: ["raiden.log", "raiden.1.log", "raiden.2.log", "raiden.3.log"]) && !names.contains("raiden.4.log"))
    let cur = (try? String(contentsOf: ld.appendingPathComponent("raiden.log"), encoding: .utf8)) ?? ""
    check("最後の行が書かれている", cur.contains("[ERROR] エラーの行"))
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)], ofItemAtPath: ld.appendingPathComponent("raiden.3.log").path)
    log.pruneOld()
    check("30 日より古い回したファイルは消す", !fm.fileExists(atPath: ld.appendingPathComponent("raiden.3.log").path))

    try? fm.removeItem(at: tmp)
    check("一時フォルダを消した", !fm.fileExists(atPath: tmp.path))
    print(fails == 0 ? "すべて OK" : "失敗 \(fails) 件")
}

/// 検索の記録で答え合わせ（raiden-eval --log-eval --store <コピーした raiden.sqlite>）。
/// 選んで開いた記録を今の並べ方で回し直し、当時の順位と今の順位を比べる（重みを変えたときの確かめ用）
func runLogEval(apps: [AppEntry]) throws {
    guard let sp = opt("--store"), sp != Store.defaultURL.path else { print("--store <コピーした raiden.sqlite> を渡してください"); return }
    let store = try Store(url: URL(fileURLWithPath: sp))
    let e = Engine(store: store, exclude: RaidenSettings().exclude)
    e.setApps(apps)
    e.loadExamples()
    let rows = store.searchLog(limit: 100_000).filter { ($0.chosenRank ?? 0) > 0 && $0.chosenKey != nil }
    var then1 = 0, then3 = 0, now1 = 0, now3 = 0
    var moved: [String] = []
    for r in rows {
        let ranked: [String] = r.chosenKind == "app" ? e.search(r.query, limit: 9).map(\.app.key) : e.searchFiles(r.query, limit: 9).map(\.file.path)
        // 当時の順位は画面の並び（アプリとファイルを合わせた順）なので、同じ節の中の順位に直して比べる
        let sec = r.chosenKind == "app" ? "app" : "file"
        let thenRank = r.candidates.filter { $0.section == sec }.firstIndex { $0.key == r.chosenKey }.map { $0 + 1 } ?? 99
        let nowRank = ranked.firstIndex(of: r.chosenKey!).map { $0 + 1 } ?? 99
        if thenRank == 1 { then1 += 1 }; if thenRank <= 3 { then3 += 1 }
        if nowRank == 1 { now1 += 1 }; if nowRank <= 3 { now3 += 1 }
        if nowRank != thenRank { moved.append("  \(r.query) → \(r.chosenName ?? "")  当時 \(thenRank) 位 → 今 \(nowRank) 位") }
    }
    print("記録 \(rows.count) 件（選んで開いたもの、節の中の順位）")
    print("  当時: 1位 \(then1)  3位以内 \(then3)")
    print("  今  : 1位 \(now1)  3位以内 \(now3)")
    if args.contains("--miss") { moved.forEach { print($0) } }
}
