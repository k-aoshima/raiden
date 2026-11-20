import Foundation
import RaidenCore

/// 書き出した一覧（JSON。--dump-entries と同じ項目に kind・size・usedDays・downloaded・parentName を足した物）を読む。
/// 計測のたびに ~/Project 16 万件を OS に問い合わせ直さない（1 回 3 分以上かかる）ため
func loadEntriesJSON(_ path: String) throws -> [FileEntry] {
    struct Row: Decodable {
        let path: String, name: String, parentName: String, isDir: Bool, kind: String, families: [String]
        let size: Int, mtime: Int, created: Int, added: Int, lastUsed: Int, usedDays: [Int], downloaded: Bool
    }
    let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    return rows.map {
        FileEntry(path: $0.path, name: $0.name, parentName: $0.parentName, isDir: $0.isDir, kind: $0.kind, families: $0.families,
                  size: $0.size, mtime: $0.mtime, created: $0.created, added: $0.added, lastUsed: $0.lastUsed,
                  usedDays: $0.usedDays, downloaded: $0.downloaded)
    }
}

/// 起動から一覧が使えるまで（raiden-eval --startup-bench --entries <一覧の JSON> --roots ~/Project --file-store <scratch の新しいファイル>）。
/// 1. 保存の中身の戻し方の確かめ（全件 encoded → 戻して同じか）
/// 2. 1 回目の起動（保存した一覧が無い）: 一覧を全部入れて保存（OS への問い合わせの代わりに JSON を使う）
/// 3. 2 回目の起動: 新しい Engine で保存した一覧を読んで入れるまで。中身が 1 回目と同じか
func runStartupBench(embedder: Embedder) throws {
    guard let sp = opt("--file-store"), sp != Store.defaultURL.path else { print("--file-store <scratch の新しいファイル> を渡してください"); return }
    guard let jp = opt("--entries") else { print("--entries <一覧の JSON> を渡してください"); return }
    var t = Date()
    let list = try loadEntriesJSON(jp)
    print(String(format: "一覧の JSON %d 件 %.1fs", list.count, Date().timeIntervalSince(t)))
    // 1. 戻し方
    var bad = 0, bytes = 0
    for e in list {
        let d = e.encoded
        bytes += d.count
        if FileEntry(path: e.path, isDir: e.isDir, encoded: d) != e {
            bad += 1
            if bad <= 3 { print("  戻すと違う: \(e)\n    → \(String(describing: FileEntry(path: e.path, isDir: e.isDir, encoded: d)))") }
        }
    }
    print(String(format: "保存の中身: 平均 %.1f バイト/件、戻すと違う %d 件", Double(bytes) / Double(max(list.count, 1)), bad))

    let roots = (opt("--roots") ?? "~/Project").split(separator: ",").map { String($0) }
    let scope = ScanScope(roots: roots)
    func fileSize() -> Int {
        let a = (try? FileManager.default.attributesOfItem(atPath: sp)[.size] as? Int) ?? 0
        let w = (try? FileManager.default.attributesOfItem(atPath: sp + "-wal")[.size] as? Int) ?? 0
        return a + w
    }
    // 2. 1 回目
    do {
        let store = try Store(url: URL(fileURLWithPath: sp))
        let e = Engine(embedder: CachedEmbedder(embedder), store: store)
        let idx = FileIndex(engine: e, scope: scope)
        idx.background = true
        t = Date()
        idx.beginScan()
        idx.finishScan(list, scope: scope)
        print(String(format: "1 回目（保存した一覧なし。OS への問い合わせは除く）入れ直し＋保存 %.1fs（うち保存 %.1fs）", Date().timeIntervalSince(t), idx.lastSaveSeconds))
        let tm = e.lastInstallTiming
        print(String(format: "  installFiles 計 %.2fs", tm.reduce(0) { $0 + $1.1 }))
        for (k, v) in tm { print(String(format: "    %-32@ %7.3fs", k as NSString, v)) }
        let eb = store.fileEntryBytes()
        print(String(format: "  一覧の中身 %d 件 %.1fMB（%.1f バイト/件）DB とWAL %.1fMB", eb.count, Double(eb.bytes) / 1_048_576,
                     Double(eb.bytes) / Double(max(eb.count, 1)), Double(fileSize()) / 1_048_576))
        let d1 = e.fileStateDigest()
        // 3. 2 回目（別の Store・Engine で読み直す）
        let store2 = try Store(url: URL(fileURLWithPath: sp))
        print(String(format: "  DB（書き戻した後）%.1fMB", Double(fileSize()) / 1_048_576))
        let e2 = Engine(embedder: CachedEmbedder(embedder), store: store2)
        let idx2 = FileIndex(engine: e2, scope: scope)
        idx2.background = true
        t = Date()
        let tl = Date()
        let saved = store2.loadFileEntries()
        let tLoad = Date().timeIntervalSince(tl)
        _ = saved
        t = Date()
        let ok = idx2.loadSaved()
        let tAll = Date().timeIntervalSince(t)
        print(String(format: "2 回目の起動: 保存した一覧から入れる %@ %d 件 %.2fs（うち一覧を読む %.2fs）", ok ? "済み" : "失敗", e2.files.count, tAll, tLoad))
        for (k, v) in e2.lastInstallTiming { print(String(format: "    %-32@ %7.3fs", k as NSString, v)) }
        let qs = ["請求書のPDF", "README", "設計書", "#kind image", "Unity のシーン"]
        for q in qs {
            let t1 = Date(); _ = e2.searchFilesJudged(q, limit: 9)
            print(String(format: "  検索 %@ %.0fms", q, Date().timeIntervalSince(t1) * 1000))
        }
        let d2 = e2.fileStateDigest()
        let diff = Set(d1.keys).union(d2.keys).filter { d1[$0] != d2[$0] }
        print("  1 回目と 2 回目の点の中身: \(d1.count) 件中 違う \(diff.count) 件")
        for k in diff.prefix(3) { print("    \(k)\n      1: \(d1[k] ?? "なし")\n      2: \(d2[k] ?? "なし")") }
    }
}

/// 止まっている間の変化が起動後に入るかの確かめ（raiden-eval --offline-test --store <scratch の新しいファイル> [--bench-root <scratch のフォルダ>]）。
/// bench-root だけを範囲にして全体を見直し（一覧とイベント ID を保存）、アプリを止めた体で足す・消す・名前を変える・書き換える・
/// フォルダごと入れる。そのあと新しい Engine で保存した一覧を読み、保存したイベント ID から FSEvents を受け取って当てる
func runOfflineTest(embedder: Embedder) throws {
    guard let sp = opt("--store"), sp != Store.defaultURL.path else { print("--store <scratch の新しいファイル> を渡してください"); return }
    let fm = FileManager.default
    let root = ((opt("--bench-root") ?? (NSTemporaryDirectory() + "raiden-offline-\(getpid())")) as NSString).expandingTildeInPath
    try? fm.removeItem(atPath: root)
    try fm.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    let scope = ScanScope(roots: [root])
    let r = scope.roots[0]
    for n in ["消す", "名前を変える", "書き換える", "そのまま"] { try "\(n) の中身".write(toFile: r + "/\(n).txt", atomically: false, encoding: .utf8) }
    try "下の物".write(toFile: r + "/sub/下の物.txt", atomically: false, encoding: .utf8)
    var failures = 0
    func check(_ label: String, _ ok: Bool) { print("  \(ok ? "OK" : "NG") \(label)"); if !ok { failures += 1 } }
    do {
        let store = try Store(url: URL(fileURLWithPath: sp))
        let e = Engine(embedder: CachedEmbedder(embedder), store: store)
        let idx = FileIndex(engine: e, scope: scope)
        idx.fullScan()
        print("止める前: \(e.files.count) 件、保存したイベント ID \(idx.savedEventId().map(String.init) ?? "なし")")
    }
    // 止まっている間の変化
    Thread.sleep(forTimeInterval: 1.1)
    try fm.removeItem(atPath: r + "/消す.txt")
    try fm.moveItem(atPath: r + "/名前を変える.txt", toPath: r + "/名前を変えた.txt")
    try "書き換えた 中身 りんご みかん".write(toFile: r + "/書き換える.txt", atomically: true, encoding: .utf8)
    try "止まっている間に足した zq9".write(toFile: r + "/足した.txt", atomically: false, encoding: .utf8)
    try fm.createDirectory(atPath: r + "/入れたフォルダ/中", withIntermediateDirectories: true)
    for i in 0..<3 { try "入れた \(i)".write(toFile: r + "/入れたフォルダ/中/入れた-\(i).txt", atomically: false, encoding: .utf8) }
    try fm.removeItem(atPath: r + "/sub")
    let newSize = (try? fm.attributesOfItem(atPath: r + "/書き換える.txt")[.size] as? Int) ?? -1
    Thread.sleep(forTimeInterval: 2)   // FSEvents の記録に載るまで

    let store = try Store(url: URL(fileURLWithPath: sp))
    let e = Engine(embedder: CachedEmbedder(embedder), store: store)
    let idx = FileIndex(engine: e, scope: scope)
    let q = DispatchQueue(label: "raiden.files")
    let since = idx.savedEventId()
    let loaded = q.sync { idx.loadSaved() }
    check("保存した一覧から入る（\(e.files.count) 件）", loaded && since != nil)
    check("起動した直後はまだ止める前の一覧", e.hasFile(r + "/消す.txt") && !e.hasFile(r + "/足した.txt"))
    var done = false
    let t = Date()
    let w = FSWatcher(paths: [r], since: since) { c in
        q.async {
            let st = idx.apply(c)
            print(String(format: "    [変化] 当てた %d 件・外した %d 件（%@）%.3fs%@", st.changed, st.removed, st.incremental ? "差分" : "全部",
                         st.seconds, c.historyDone ? "  止まっていた間の分は受け取り終えた" : ""))
            if c.historyDone { done = true }
        }
    }
    while !q.sync(execute: { done }) && Date().timeIntervalSince(t) < 15 { Thread.sleep(forTimeInterval: 0.05) }
    Thread.sleep(forTimeInterval: 1.5)   // 受け取り終えた印の後に残りがまとめて来る分
    w?.stop()
    print(String(format: "  止まっていた間の変化を受け取るまで %.2fs", Date().timeIntervalSince(t)))
    let files = q.sync { Set(e.files.map(\.path)) }
    check("消した物が消える", !files.contains(r + "/消す.txt"))
    check("名前を変えた物が新しい名前になる", files.contains(r + "/名前を変えた.txt") && !files.contains(r + "/名前を変える.txt"))
    check("書き換えた物の大きさが新しい", q.sync { e.files.first { $0.path == r + "/書き換える.txt" }?.size } == newSize)
    check("足した物が入る", files.contains(r + "/足した.txt"))
    check("入れたフォルダの中も入る", (0..<3).allSatisfy { files.contains(r + "/入れたフォルダ/中/入れた-\($0).txt") } && files.contains(r + "/入れたフォルダ/中"))
    check("消したフォルダの中も消える", !files.contains(r + "/sub") && !files.contains(r + "/sub/下の物.txt"))
    check("そのままの物は残る", files.contains(r + "/そのまま.txt"))
    q.sync { idx.embedAll() }
    check("足した物が検索に出る", e.searchFiles("止まっている間に足した zq9", limit: 5).contains { $0.file.path == r + "/足した.txt" })
    // 保存した一覧にも当たっているか（もう一度起動した体）
    let e3 = Engine(embedder: CachedEmbedder(embedder), store: try Store(url: URL(fileURLWithPath: sp)))
    let idx3 = FileIndex(engine: e3, scope: scope)
    _ = idx3.loadSaved()
    check("もう一度起動すると同じ一覧", Set(e3.files.map(\.path)) == files)
    check("イベント ID が進んでいる", (idx3.savedEventId() ?? 0) > (since ?? 0))
    print(failures == 0 ? "止まっている間の変化: 全部 OK" : "止まっている間の変化: NG \(failures) 件")
}

/// co_time の線が前の作り（窓の中を毎回集め直す）と同じかの確かめ（raiden-eval --check-cotime --entries <一覧の JSON>）
func runCheckCoTime() throws {
    guard let jp = opt("--entries") else { print("--entries <一覧の JSON> を渡してください"); return }
    let entries = try loadEntriesJSON(jp).sorted { $0.path < $1.path }
    func old(_ entries: [FileEntry], window: Int = 1800, maxGroup: Int = 8) -> [(Int, Int, Float)] {
        var ev: [(Int, Int)] = []
        for (i, e) in entries.enumerated() where !e.isDir {
            for t in Set([e.mtime, e.added, e.lastUsed]) where t > 0 { ev.append((t, i)) }
        }
        ev.sort { $0.0 < $1.0 }
        let parent = entries.map { ($0.path as NSString).deletingLastPathComponent }
        var w: [Int64: Float] = [:]
        var lo = 0
        for hi in 0..<ev.count {
            while ev[hi].0 - ev[lo].0 > window { lo += 1 }
            let group = Set(ev[lo...hi].map(\.1))
            if group.count > maxGroup { continue }
            let b = ev[hi].1
            for a in group where a != b && parent[a] != parent[b] { w[Int64(min(a, b)) << 32 | Int64(max(a, b))] = 1 }
        }
        return w.map { (Int($0.key >> 32), Int($0.key & 0xffffffff), $0.value) }
    }
    var t = Date()
    let a = old(entries)
    let ta = Date().timeIntervalSince(t)
    t = Date()
    let b = FileCatalog.coTimeEdges(entries)
    let tb = Date().timeIntervalSince(t)
    let sa = Set(a.map { "\($0.0)-\($0.1)-\($0.2)" }), sb = Set(b.map { "\($0.0)-\($0.1)-\($0.2)" })
    print(String(format: "co_time %d 件: 前 %d 本 %.2fs / 今 %d 本 %.2fs  %@", entries.count, sa.count, ta, sb.count, tb, sa == sb ? "同じ" : "違う"))
}
