import Foundation
import RaidenCore

/// FSEvents で変化をすぐ拾えるかの確かめ（raiden-eval --watch-test --store <コピーした raiden.sqlite>）。
/// ~/Documents/raiden-test-<pid> を作り、テキストを作る・書き換える・名前を変える・消す、100 個まとめて作る・消す、を行い、
/// 検索（Engine.searchFiles）に出る／消えるまでの時間を測る。最後にフォルダごと消す。ユーザーのファイルには触らない。
/// Store はアプリと同じ物を使わないよう、コピーを --store で渡す。
func runWatchTest(embedder: Embedder) throws {
    guard let sp = opt("--store") else { print("--store <コピーした raiden.sqlite> を渡してください"); return }
    let store = try Store(url: URL(fileURLWithPath: sp))
    let e = Engine(embedder: CachedEmbedder(embedder), store: store)
    let q = DispatchQueue(label: "raiden.files", qos: .utility)
    let idx = FileIndex(engine: e)
    let fm = FileManager.default

    var t = Date()
    let watcher = FSWatcher(paths: idx.roots) { c in
        q.async {
            let st = idx.apply(c)
            print(String(format: "    [変化] 当てた %d 件・外した %d 件・ベクトル化 %d 件  %.2fs", st.changed, st.removed, st.embedded, st.seconds))
        }
    }
    guard watcher != nil else { print("FSEvents を始められませんでした"); return }
    let full = q.sync { idx.fullScan() }
    print(String(format: "全体の見直し %d 件（ベクトル化 %d 件）%.1fs  メモリ footprint %.0fMB", full.changed, full.embedded, Date().timeIntervalSince(t), physFootprintMB()))
    t = Date()
    _ = q.sync { idx.apply(FSWatcher.Change()) }
    print(String(format: "変化なしで Engine に入れ直す手間 %.0fms（1 回の変化ごとにかかる下限）", Date().timeIntervalSince(t) * 1000))

    let dir = NSHomeDirectory() + "/Documents/raiden-test-\(getpid())"
    func inEngine(_ p: String) -> Bool { e.files.contains { $0.path == p } }
    func underDir(_ d: String) -> Int { e.files.filter { $0.path == d || $0.path.hasPrefix(d + "/") }.count }
    func top(_ query: String) -> [String] { e.searchFiles(query, limit: 5).map(\.file.path) }
    /// cond が真になるまでの秒数（timeout 秒で諦めて nil）
    func wait(_ timeout: Double = 15, _ cond: () -> Bool) -> Double? {
        let s = Date()
        while Date().timeIntervalSince(s) < timeout {
            if cond() { return Date().timeIntervalSince(s) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }
    func report(_ label: String, _ s: Double?) {
        print("  \(label): " + (s.map { String(format: "%.2fs", $0) } ?? "15 秒たっても出ない（失敗）"))
    }
    defer {
        try? fm.removeItem(atPath: dir)
        let s = wait { underDir(dir) == 0 }
        report("後片付け（テスト用フォルダを消して一覧から消えるまで）", s)
        print("  テスト用フォルダ \(fm.fileExists(atPath: dir) ? "残っている" : "消した")")
    }

    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let a = dir + "/raiden-test-zq7-猫の観察メモ.txt"
    let b = dir + "/raiden-test-zq7-犬の散歩メモ.txt"
    print("変化から検索に出るまで（静かになって 0.6 秒まとめる＋FSEvents の遅れ 0.2 秒を含む）")
    try "ねこ 観察 メモ zq7".write(toFile: a, atomically: false, encoding: .utf8)
    report("作る（検索の上位 5 件に出る）", wait { top("raiden-test-zq7 猫の観察メモ").contains(a) })

    try "ねこ 観察 メモ zq7 追記 りんごを食べた".write(toFile: a, atomically: true, encoding: .utf8)
    let newSize = (try? fm.attributesOfItem(atPath: a)[.size] as? Int) ?? -1
    report("書き換える（新しい大きさが一覧に入る）", wait { e.files.first { $0.path == a }?.size == newSize })

    try fm.moveItem(atPath: a, toPath: b)
    report("名前を変える（新しい名前が検索に出て、古い名前が消える）", wait { top("raiden-test-zq7 犬の散歩メモ").contains(b) && !inEngine(a) })

    try fm.removeItem(atPath: b)
    report("消す（一覧から消える）", wait { !inEngine(b) })

    // 100 個まとめて作る
    let bulk = dir + "/bulk"
    var r0 = rusage(); getrusage(RUSAGE_SELF, &r0)
    let fp0 = physFootprintMB()
    var peakFP = fp0, peakRes = residentMB()
    var lat: [Double] = []
    let start = Date()
    try fm.createDirectory(atPath: bulk, withIntermediateDirectories: true)
    for i in 0..<100 {
        try "まとめて作ったテスト \(i) 番 zq7 りんご みかん".write(toFile: bulk + "/zq7-bulk-\(i).txt", atomically: false, encoding: .utf8)
    }
    // 取り込みの間も検索を打ち続け、1 回の時間を測る（もたつかないか）
    let s = wait(60) {
        let t1 = Date()
        _ = e.searchFiles("請求書のPDF", limit: 9)
        lat.append(Date().timeIntervalSince(t1) * 1000)
        peakFP = max(peakFP, physFootprintMB()); peakRes = max(peakRes, residentMB())
        return underDir(bulk) == 101
    }
    var r1 = rusage(); getrusage(RUSAGE_SELF, &r1)
    func sec(_ v: timeval) -> Double { Double(v.tv_sec) + Double(v.tv_usec) / 1e6 }
    let cpu = sec(r1.ru_utime) + sec(r1.ru_stime) - sec(r0.ru_utime) - sec(r0.ru_stime)
    let wall = Date().timeIntervalSince(start)
    report("100 個まとめて作る（全部一覧に入る）", s)
    lat.sort()
    print(String(format: "    CPU %.1fs（%.0f%%、1 コア＝100%%）  メモリ footprint %.0f → 最大 %.0fMB  resident 最大 %.0fMB",
                 cpu, cpu / max(wall, 0.001) * 100, fp0, peakFP, peakRes))
    if !lat.isEmpty {
        print(String(format: "    取り込み中の検索 1 回: 中央 %.0fms  最大 %.0fms（%d 回）", lat[lat.count / 2], lat.last!, lat.count))
    }
    try fm.removeItem(atPath: bulk)
    report("100 個をフォルダごと消す（全部一覧から消える）", wait { underDir(bulk) == 0 })
    let leftover = store.fileExamples().filter { $0.1.hasPrefix(dir) }.count
    print("  消した物に向いた例の線: \(leftover) 本")
}
