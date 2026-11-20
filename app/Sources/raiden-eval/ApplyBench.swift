import Foundation
import RaidenCore

/// FSEvents の変化を当てる手間を広い範囲で測る（raiden-eval --bench-apply --roots ~/Project --file-store <scratch の新しいファイル>
///   [--bench-root <scratch のフォルダ>] [--full-only] [--batches 10,100,1000,5000]）。
/// 範囲は roots ＋ bench-root（ここにだけファイルを作る・書き換える・消す。roots の中には書かない）。
/// 1. 全体の入れ直し（installFiles）の段ごとの秒数
/// 2. 1 件の追加・変更・削除、N 件まとめての追加・削除の apply の秒数
/// 3. 差分で直した状態と、同じ一覧を全部入れ直した状態の比べ（点ごとの中身・検索の結果）
/// --full-only: 差分を使わず毎回全部入れ直す（前の作りの時間）
func runApplyBench(embedder: Embedder) throws {
    guard let sp = opt("--file-store"), sp != Store.defaultURL.path else { print("--file-store <scratch の新しいファイル> を渡してください"); return }
    let fm = FileManager.default
    let benchRoot = ((opt("--bench-root") ?? (NSTemporaryDirectory() + "raiden-bench-\(getpid())")) as NSString).expandingTildeInPath
    try? fm.removeItem(atPath: benchRoot)
    try fm.createDirectory(atPath: benchRoot, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: benchRoot) }
    let roots = (opt("--roots") ?? "~/Project").split(separator: ",").map { String($0) } + [benchRoot]
    let scope = ScanScope(roots: roots)
    let br = scope.roots.last!
    let store = try Store(url: URL(fileURLWithPath: sp))
    let e = Engine(embedder: CachedEmbedder(embedder), store: store)
    let idx = FileIndex(engine: e, scope: scope)
    idx.background = true
    if args.contains("--full-only") { idx.incrementalLimit = 0 }

    func showTiming(_ label: String) {
        let tm = e.lastInstallTiming
        let total = tm.reduce(0) { $0 + $1.1 }
        print(String(format: "  %@ installFiles 計 %.2fs", label, total))
        for (k, v) in tm { print(String(format: "    %-32@ %7.3fs", k as NSString, v)) }
    }
    var t = Date()
    idx.fullScan()
    print(String(format: "全体の見直し %d 件 %.1fs（一覧づくり込み、1 回目は点を全部書く）", e.files.count, Date().timeIntervalSince(t)))
    showTiming("1 回目")
    t = Date()
    idx.rebuild()
    print(String(format: "入れ直し（2 回目、点は保存済み）%.1fs", Date().timeIntervalSince(t)))
    showTiming("2 回目")

    func apply(_ paths: [String]) -> FileIndex.Stats { idx.apply(FSWatcher.Change(paths: Set(paths))) }
    func med(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
    // 1 件の追加・変更・削除（3 回ずつ）
    var add: [Double] = [], mod: [Double] = [], del: [Double] = [], ren: [Double] = []
    var how = ""
    for k in 0..<3 {
        let f = br + "/bench-one-\(k).txt"
        try "ベンチ \(k) りんご".write(toFile: f, atomically: false, encoding: .utf8)
        var st = apply([f]); add.append(st.seconds); how = st.incremental ? "差分" : "全部"
        Thread.sleep(forTimeInterval: 1.1)   // 変更日が秒単位なので
        try "ベンチ \(k) りんご みかん 追記".write(toFile: f, atomically: false, encoding: .utf8)
        st = apply([f]); mod.append(st.seconds)
        let g = br + "/bench-one-\(k)-renamed.txt"
        try fm.moveItem(atPath: f, toPath: g)
        st = apply([f, g]); ren.append(st.seconds)
        try fm.removeItem(atPath: g)
        st = apply([g]); del.append(st.seconds)
    }
    print(String(format: "1 件の apply（%@、中央値）: 追加 %.3fs  変更 %.3fs  名前変更 %.3fs  削除 %.3fs", how, med(add), med(mod), med(ren), med(del)))

    // N 件まとめて
    let batches = (opt("--batches") ?? "10,100,1000,5000").split(separator: ",").compactMap { Int($0) }
    for n in batches {
        let d = br + "/bulk-\(n)"
        try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        var ps = [d]
        for i in 0..<n {
            let f = d + "/bulk-\(i).txt"
            try "まとめて \(i)".write(toFile: f, atomically: false, encoding: .utf8)
            ps.append(f)
        }
        let a = apply(ps)
        try fm.removeItem(atPath: d)
        let r = apply(ps)
        print(String(format: "%5d 件まとめて: 追加 %.3fs（%@）  削除 %.3fs（%@）", n, a.seconds, a.incremental ? "差分" : "全部",
                     r.seconds, r.incremental ? "差分" : "全部"))
    }
    if args.contains("--full-only") { return }

    // 差分で直した状態と全部入れ直した状態の比べ
    // いろいろな変化: フォルダごと追加（中にフォルダ）、書き換え、名前変更、削除、消してから同じ名前で作り直す、例のある物を消して戻す
    print("差分と全部の入れ直しの比べ")
    let tree = br + "/比べ"
    try fm.createDirectory(atPath: tree + "/請求書/2025", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: tree + "/写真", withIntermediateDirectories: true)
    var made: [String] = [tree, tree + "/請求書", tree + "/請求書/2025", tree + "/写真"]
    for i in 0..<40 {
        let f = tree + "/請求書/2025/請求書-\(i).txt"
        try "請求書 \(i) 金額 \(i * 1000) 円".write(toFile: f, atomically: false, encoding: .utf8); made.append(f)
    }
    for i in 0..<20 {
        let f = tree + "/写真/IMG_\(i).png"
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: URL(fileURLWithPath: f)); made.append(f)
    }
    for i in 0..<10 {
        let f = tree + "/メモ-\(i).md"
        try "# メモ \(i)\n猫の観察と散歩".write(toFile: f, atomically: false, encoding: .utf8); made.append(f)
    }
    _ = apply(made)
    idx.embedAll()
    // 例: 入力 → ファイル（消してから戻すと線が付き直すか）
    let exPath = tree + "/メモ-3.md"
    store.recordFileChoice(query: "猫のメモ", path: exPath, isDir: false, name: "メモ-3.md", vector: e.embedder.embed("猫のメモ"), model: e.embedder.identifier)
    e.addFileExamples([("猫のメモ", exPath)])
    Thread.sleep(forTimeInterval: 1.1)
    // 書き換え
    for i in 0..<5 { try "請求書 \(i) 金額 訂正".write(toFile: tree + "/請求書/2025/請求書-\(i).txt", atomically: false, encoding: .utf8) }
    _ = apply((0..<5).map { tree + "/請求書/2025/請求書-\($0).txt" })
    // 名前変更（ファイルとフォルダ）
    try fm.moveItem(atPath: tree + "/メモ-0.md", toPath: tree + "/メモ-0-改.md")
    _ = apply([tree + "/メモ-0.md", tree + "/メモ-0-改.md"])
    try fm.moveItem(atPath: tree + "/写真", toPath: tree + "/旅行の写真")
    _ = apply([tree + "/写真", tree + "/旅行の写真"])
    // 削除
    for i in 5..<10 { try fm.removeItem(atPath: tree + "/請求書/2025/請求書-\(i).txt") }
    _ = apply((5..<10).map { tree + "/請求書/2025/請求書-\($0).txt" })
    // 例のある物を消して戻す
    let exBody = try String(contentsOfFile: exPath, encoding: .utf8)
    try fm.removeItem(atPath: exPath)
    _ = apply([exPath])
    // 消すと点ごと例の線も消えるので、戻したら例も記録し直す（アプリでは選び直したとき）
    try exBody.write(toFile: exPath, atomically: false, encoding: .utf8)
    _ = apply([exPath])
    store.recordFileChoice(query: "猫のメモ", path: exPath, isDir: false, name: "メモ-3.md", vector: e.embedder.embed("猫のメモ"), model: e.embedder.identifier)
    e.addFileExamples([("猫のメモ", exPath)])   // アプリの learnFile と同じく、記録したらメモリにも入れる
    // 1 件だけの追加（中身つき）
    try "猫 観察 りんご 散歩".write(toFile: tree + "/新しいメモ.txt", atomically: false, encoding: .utf8)
    _ = apply([tree + "/新しいメモ.txt"])
    idx.embedAll()

    let queries = ["請求書", "請求書 2025", "猫のメモ", "旅行の写真", "IMG_3", "メモ", "新しいメモ", "比べ フォルダ", "README", "設計書",
                   "請求書が入ってるフォルダ", "画像のフォルダ", "先週のメモ", "#kind text 請求書", "#kind image"]
    let now = Date()
    func snap() -> ([String: String], [[String]]) {
        (e.fileStateDigest(), queries.map { q in e.searchFilesJudged(q, limit: 10, now: now).results.map { $0.file.path + String(format: " %.4f", $0.score) } })
    }
    let (d1, r1) = snap()
    let dead = e.fileDeadCount
    idx.rebuild()
    idx.embedAll()
    let (d2, r2) = snap()
    var diff = 0
    for k in Set(d1.keys).union(d2.keys) where d1[k] != d2[k] {
        diff += 1
        if diff <= 8 { print("  違う: \(k)\n    差分: \(d1[k] ?? "なし")\n    全部: \(d2[k] ?? "なし")") }
    }
    print("  点の中身（説明文・stamp・ベクトル・時間・種類・下のファイル数と種類・contains の線・名前）: \(d1.count) 件中 違う \(diff) 件（差分のとき消した印 \(dead) 件）")
    var same = 0
    for (i, q) in queries.enumerated() {
        if r1[i] == r2[i] { same += 1; continue }
        print("  検索が違う: \(q)\n    差分: \(r1[i].prefix(5))\n    全部: \(r2[i].prefix(5))")
    }
    print("  検索の結果（上位 10 件と点数）: \(queries.count) 個中 同じ \(same) 個")
}
