import Foundation
import RaidenCore

/// 設定・検索範囲の差し替え・検索の記録・動作の記録の確かめ（raiden-eval --settings-test --store <コピーした raiden.sqlite>）。
/// ユーザーのファイル・本物の settings.json・ログ・DB には触らない:
///   設定は一時フォルダの settings.json、ログは一時フォルダ、DB は --store で渡したコピー。
///   検索範囲は ~/Documents/raiden-test-<pid>（初期値の範囲の中）と、一時フォルダの raiden-test-<pid>-extra（範囲の外）を作って試し、最後に消す。
func runSettingsTest(embedder: Embedder) throws {
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
    check("初期値は今の 4 か所", RaidenSettings().scope.roots == FileCatalog.defaultRoots && RaidenSettings().scope == ScanScope.default)
    var s = RaidenSettings()
    s.folders.append(.init(path: "~/raiden-test-dummy", enabled: false))
    s.folders[1].enabled = false
    s.excludeFolders = ["~/Documents/raiden-test-ex"]
    s.excludeNames.append("*.tmp")
    s.hotKey = .init(keyCode: 49, modifiers: 4096 | 2048, label: "⌃⌥Space")
    s.maxRows = 12; s.sectionOrder = .filesFirst; s.unloadMinutes = 5; s.transparency = 0.3
    s.learn = false; s.logSearches = false; s.logDays = 30
    try s.save(to: su)
    let back = RaidenSettings.load(from: su)
    check("書いて読むと同じ", back == s)
    check("範囲は有効なフォルダだけ・~ を広げる",
          back.scope.roots == [NSHomeDirectory() + "/Documents", NSHomeDirectory() + "/Desktop", NSHomeDirectory() + "/Documents/Obsidian Vault"])
    let text = (try? String(contentsOf: su, encoding: .utf8)) ?? ""
    check("保存は ~/ の形", text.contains("\"~/Documents\"") && !text.contains(NSHomeDirectory()))
    try "{ 壊れた json".write(to: su, atomically: true, encoding: .utf8)
    check("壊れていたら初期値", RaidenSettings.load(from: su) == RaidenSettings())
    try #"{"maxRows": "たくさん", "logDays": 7, "folders": [{"path": "~/Desktop", "enabled": true}], "transparency": 5}"#
        .write(to: su, atomically: true, encoding: .utf8)
    let part = RaidenSettings.load(from: su)
    check("読めない項目だけ初期値（maxRows 9・logDays 7・フォルダ 1 つ・透明度は 0.9 まで）",
          part.maxRows == 9 && part.logDays == 7 && part.folders.count == 1 && part.transparency == 0.9)
    let sc = ScanScope(roots: ["~/x"], excludeDirs: ["~/x/skip"], excludeNames: ["node_modules", "*.tmp", "build?"])
    check("除外の名前（そのまま・* ・?・隠し・.app）",
          sc.excludesName("node_modules") && sc.excludesName("a.tmp") && sc.excludesName("build1") && !sc.excludesName("build10")
          && sc.excludesName(".DS_Store") && sc.excludesName("Foo.app") && !sc.excludesName("memo.txt"))
    check("除外のフォルダ（その中も・名前が前方一致なだけの隣は除かない）",
          sc.excludesPath(NSHomeDirectory() + "/x/skip/a") && !sc.excludesPath(NSHomeDirectory() + "/x/skipper"))

    // MARK: 範囲の差し替え
    print("検索範囲の差し替え（\(sp) のコピー）")
    let store = try Store(url: URL(fileURLWithPath: sp))
    let e = Engine(embedder: CachedEmbedder(embedder), store: store)
    let docs = NSHomeDirectory() + "/Documents/raiden-test-\(pid)"
    let extra = tmp.appendingPathComponent("raiden-test-\(pid)-extra").path
    defer {
        try? fm.removeItem(atPath: docs)
        try? fm.removeItem(atPath: extra)
    }
    try fm.createDirectory(atPath: docs + "/sub", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: extra + "/inner", withIntermediateDirectories: true)
    let dA = docs + "/raiden-test-qx8-ペンギンの飼育メモ.txt"
    let dB = docs + "/sub/raiden-test-qx8-フラミンゴの観察.txt"
    let dTmp = docs + "/raiden-test-qx8-一時ファイル.zq9tmp"
    let xA = extra + "/raiden-test-qx8-カピバラの温泉メモ.txt"
    let xB = extra + "/inner/raiden-test-qx8-アルパカの毛刈り.txt"
    for (p, body) in [(dA, "ペンギン 飼育 水槽 qx8"), (dB, "フラミンゴ 観察 qx8"), (dTmp, "一時 qx8"),
                      (xA, "カピバラ 温泉 qx8"), (xB, "アルパカ 毛刈り qx8")] {
        try body.write(toFile: p, atomically: true, encoding: .utf8)
    }
    let idx = FileIndex(engine: e)
    var t = Date()
    let full = idx.fullScan()
    print(String(format: "  全体の見直し %d 件（ベクトル化 %d 件）%.1fs", full.changed, full.embedded, Date().timeIntervalSince(t)))
    func has(_ p: String) -> Bool { e.files.contains { $0.path == p } }
    func top(_ q: String) -> [String] { e.searchFiles(q, limit: 5).map(\.file.path) }
    check("初期値の範囲: ~/Documents の中は入る・範囲の外は入らない", has(dA) && has(dB) && !has(xA))

    // 足す
    var sc2 = RaidenSettings()
    sc2.folders.append(.init(path: extra))
    t = Date()
    var st = idx.setScope(sc2.scope)
    print(String(format: "  フォルダを足す: 増えた %d 件（ベクトル化 %d 件）%.2fs", st.changed, st.embedded, Date().timeIntervalSince(t)))
    check("足したフォルダの物が一覧に入る（中のフォルダも）", has(xA) && has(xB) && has(extra + "/inner"))
    check("ベクトル化は増えた物だけ（3 件: 2 ファイル＋1 フォルダ。ほかは作り直さない）", st.embedded == 3)
    check("足したフォルダの物が検索に出る", top("raiden-test-qx8 カピバラの温泉メモ").contains(xA))
    check("SQLite に点が入る", store.hasFileNode(xA))
    // 外したときに chose の線も消えるか見るため、足した物を選んだ例を残す
    let q = "raiden-test-qx8 温泉の動物のメモ"
    store.recordFileChoice(query: q, path: xA, isDir: false, name: (xA as NSString).lastPathComponent,
                           vector: e.embedder.embed(q), model: e.embedder.identifier)
    check("例（chose の線）が入る", store.fileExamples().contains { $0.0 == q && $0.1 == xA })
    check("覚えた例の一覧に出る", store.learnedExamples().contains { $0.query == q && $0.key == xA && $0.kind == "file" })

    // 外す
    t = Date()
    st = idx.setScope(ScanScope.default)
    print(String(format: "  フォルダを外す: 外した %d 件（ベクトル化 %d 件）%.2fs", st.removed, st.embedded, Date().timeIntervalSince(t)))
    check("外したフォルダの物が一覧から消える", !has(xA) && !has(xB))
    check("外したフォルダの物が検索に出ない", !top("raiden-test-qx8 カピバラの温泉メモ").contains(xA))
    check("SQLite から点が消える", !store.hasFileNode(xA) && !store.hasFileNode(xB))
    check("外した物に向いた chose の線も消える", !store.fileExamples().contains { $0.1 == xA })
    check("線の無くなった例は覚えた例の一覧に出ない", !store.learnedExamples().contains { $0.query == q })
    check("ほかのフォルダはそのまま", has(dA) && has(dB))

    // 除外するフォルダ
    var sc3 = RaidenSettings()
    sc3.excludeFolders = [RaidenSettings.tilde(docs + "/sub")]
    st = idx.setScope(sc3.scope)
    check("除外したフォルダの中が消える（SQLite からも）", !has(dB) && !store.hasFileNode(dB) && has(dA))
    // 除外する名前
    var sc4 = RaidenSettings()
    sc4.excludeNames.append("*.zq9tmp")
    st = idx.setScope(sc4.scope)
    check("除外する名前（*.zq9tmp）に合う物が消え、除外をやめたフォルダは戻る", !has(dTmp) && has(dB) && has(dA))
    check("戻った物は検索に出る", top("raiden-test-qx8 フラミンゴの観察").contains(dB))
    // 外した後に FSEvents の当て方も範囲に従うか（範囲の外の変化は無視）
    _ = idx.apply(FSWatcher.Change(paths: [xA]))
    check("範囲の外の変化は一覧に入れない", !has(xA))

    // 覚えた例の削除
    let q2 = "raiden-test-qx8 ペンギンのメモ"
    store.recordFileChoice(query: q2, path: dA, isDir: false, name: "p", vector: e.embedder.embed(q2), model: e.embedder.identifier)
    let had = store.learnedExamples().contains { $0.query == q2 }
    store.deleteLearned(query: q2, kind: "file", key: dA)
    check("覚えた例を 1 件消せる", had && !store.learnedExamples().contains { $0.query == q2 } && !store.fileExamples().contains { $0.0 == q2 })

    // 後片付け（テスト用フォルダの点を SQLite のコピーからも消す）
    try? fm.removeItem(atPath: docs)
    try? fm.removeItem(atPath: extra)
    idx.setScope(ScanScope.default)
    _ = idx.fullScan()
    check("後片付け: テスト用フォルダを消して一覧からも消える", !has(dA) && !store.hasFileNode(dA) && !fm.fileExists(atPath: docs))

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
    check("一時フォルダを消した", !fm.fileExists(atPath: tmp.path) && !fm.fileExists(atPath: docs))
    print(fails == 0 ? "すべて OK" : "失敗 \(fails) 件")
}

/// 検索の記録で答え合わせ（raiden-eval --log-eval --store <コピーした raiden.sqlite>）。
/// 選んで開いた記録を今の並べ方で回し直し、当時の順位と今の順位を比べる（重みを変えたときの確かめ用）
func runLogEval(embedder: Embedder, apps: [AppEntry]) throws {
    guard let sp = opt("--store") else { print("--store <コピーした raiden.sqlite> を渡してください"); return }
    let store = try Store(url: URL(fileURLWithPath: sp))
    let e = Engine(embedder: CachedEmbedder(embedder), store: store)
    e.setApps(apps)
    e.loadExamples()
    let idx = FileIndex(engine: e, scope: RaidenSettings.load().scope)
    idx.fullScan()
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
