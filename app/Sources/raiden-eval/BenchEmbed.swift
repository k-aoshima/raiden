// ベクトル化の速さとメモリを測る（ファイルの説明文をまとめてベクトル化するときの比べ）。
//
//   raiden-eval --bench-embed [--model-dir <dir>] [--body body.mlmodelc] [--units cpu|ane|gpu|all]
//               [--roots ~/Project,~/Documents] [--n 384] [--batches 1,8,16,32,64] [--provider] [--short]
//
// 範囲の中の物から n 件を等間隔に選び、アプリと同じ説明文（名前・場所・種類＋中身の頭）を作って、
// 1 件ずつ（embed）と B 件ずつ（embedBatch）で 1 件あたりの時間・1 万件の見込み・メモリの山を出す。
// 1 件ずつの結果との cos の差の最大と、裏でまとめて作っている最中の入力 1 文の埋め込み時間も出す。
// --short は中身を入れない短い説明文だけ。--provider は件数の次元を持たないモデルに MLArrayBatchProvider で渡す。
import CoreML
import Foundation
import RaidenCore

final class PeakMeter {
    private var timer: DispatchSourceTimer?
    private(set) var footprint: Double = 0
    private(set) var resident: Double = 0
    func start() {
        footprint = physFootprintMB(); resident = residentMB()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "peak"))
        t.schedule(deadline: .now(), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.footprint = max(self.footprint, physFootprintMB())
            self.resident = max(self.resident, residentMB())
        }
        t.resume()
        timer = t
    }
    func stop() { timer?.cancel(); timer = nil }
}

func runBenchEmbed() throws {
    let home = NSHomeDirectory()
    let roots = (opt("--roots").map { $0.split(separator: ",").map { String($0) } } ?? FileCatalog.defaultRoots)
        .map { ($0 as NSString).expandingTildeInPath }
    // --legacy-excludes: 前の除外の初期値（node_modules .venv venv __pycache__ .git DerivedData Pods）で数える
    let scope = ScanScope(roots: roots, excludeNames: args.contains("--legacy-excludes") ? ScanScope.legacyExcludeNames : ScanScope.defaultExcludeNames)
    var t = Date()
    let all = FileCatalog.collect(scope: scope)
    print("範囲 \(roots.map { $0.replacingOccurrences(of: home, with: "~") }) \(all.count) 件（一覧 \(String(format: "%.1f", Date().timeIntervalSince(t)))s）")
    if args.contains("--count-only") {
        // 多い場所（2 段目のフォルダごと）
        var by: [String: Int] = [:]
        for e in all {
            let rel = e.path.dropFirst(home.count + 1).split(separator: "/").prefix(3).joined(separator: "/")
            by[rel, default: 0] += 1
        }
        for (k, v) in by.sorted(by: { $0.value > $1.value }).prefix(12) { print("  \(v)\t\(k)") }
        var ext: [String: Int] = [:]
        for e in all where !e.isDir { ext[(e.name as NSString).pathExtension.lowercased(), default: 0] += 1 }
        print("  拡張子: " + ext.sorted { $0.value > $1.value }.prefix(15).map { "\($0.key) \($0.value)" }.joined(separator: " "))
        exit(0)
    }
    let n = min(Int(opt("--n") ?? "384") ?? 384, all.count)
    let step = max(1, all.count / max(n, 1))
    let sample = stride(from: 0, to: all.count, by: step).prefix(n).map { all[$0] }
    let cm = FileCatalog.childrenMap(all)
    t = Date()
    let short = args.contains("--short")
    let texts = sample.map { e -> String in
        let b = FileCatalog.baseDescription(e, children: cm[e.path] ?? [])
        if short { return b }
        let c = FileCatalog.content(e)
        return c.isEmpty ? b : b + " 中身: " + c
    }
    print("説明文 \(texts.count) 件（\(short ? "短い説明だけ" : "中身あり")、作る \(String(format: "%.1f", Date().timeIntervalSince(t)))s）")

    let dir = URL(fileURLWithPath: opt("--model-dir") ?? "/Volumes/SSD/raiden-models")
    let unitName = opt("--units") ?? "cpu"
    let units: MLComputeUnits = ["cpu": .cpuOnly, "gpu": .cpuAndGPU, "all": .all, "ane": .cpuAndNeuralEngine][unitName] ?? .cpuOnly
    let fp0 = physFootprintMB(), rs0 = residentMB()
    let b = try BGEEmbedder(modelDir: dir, body: opt("--body") ?? "body.mlmodelc", computeUnits: units)
    t = Date()
    try b.load()
    let toks = texts.map { b.tokenize($0).count }
    print(String(format: "モデル %@ %@ 件数の次元 %@  読み込み %.2fs  footprint %.0f→%.0fMB resident %.0f→%.0fMB  トークン数 平均 %.0f 最大 %d（%d 以上 %d 件）",
                 dir.lastPathComponent, unitName, b.batchSizes.description, Date().timeIntervalSince(t), fp0, physFootprintMB(), rs0, residentMB(),
                 Double(toks.reduce(0, +)) / Double(max(toks.count, 1)), toks.max() ?? 0, b.maxTokens, toks.filter { $0 >= b.maxTokens }.count))

    let q = "先週ダウンロードした請求書のPDF"
    func queryMs(_ k: Int = 15) -> (Double, Double) {
        var ts: [Double] = []
        for _ in 0..<k { let t = Date(); _ = b.embed(q); ts.append(Date().timeIntervalSince(t) * 1000) }
        return (ts.sorted()[ts.count / 2], ts.max() ?? 0)
    }
    t = Date()
    _ = b.embed(texts[0])
    print(String(format: "1 回目（コンパイル込み）%.2fs", Date().timeIntervalSince(t)))
    let qa = queryMs()
    print(String(format: "検索 1 文: 中央値 %.1fms 最大 %.1fms", qa.0, qa.1))

    let meter = PeakMeter()
    meter.start()
    t = Date()
    let ref = texts.map { b.embed($0) }
    let single = Date().timeIntervalSince(t) * 1000 / Double(texts.count)
    meter.stop()
    print(String(format: "  B=1（1 件ずつ）: %.1fms/件  1 万件 %.1f 分  山 footprint %.0fMB resident %.0fMB", single, single * 10000 / 60000, meter.footprint, meter.resident))

    let batches = (opt("--batches") ?? "8,16,32,64").split(separator: ",").compactMap { Int($0) }
    b.useBatchProvider = args.contains("--provider")
    for B in batches where B > 1 {
        // 1 回目は形ごとのコンパイル（ANE）があるので、測る前に 1 回まわす
        let tw = Date()
        _ = b.embedBatch(Array(texts.prefix(B * 2)), batch: B)
        let warm = Date().timeIntervalSince(tw)
        let m = PeakMeter()
        m.start()
        t = Date()
        let vs = b.embedBatch(texts, batch: B)
        let per = Date().timeIntervalSince(t) * 1000 / Double(texts.count)
        m.stop()
        let maxDiff = zip(ref, vs).map { 1 - Vec.dot($0, $1) }.max() ?? 0
        // 裏でまとめて作っている間の、入力 1 文の埋め込み時間
        let done = DispatchSemaphore(value: 0)
        var running = true
        DispatchQueue.global(qos: .utility).async { _ = b.embedBatch(texts, batch: B); running = false; done.signal() }
        var during: [Double] = []
        while running && during.count < 40 {
            let t1 = Date(); _ = b.embed(q); during.append(Date().timeIntervalSince(t1) * 1000)
            Thread.sleep(forTimeInterval: 0.05)
        }
        done.wait()
        let dm = during.isEmpty ? 0 : during.sorted()[during.count / 2]
        print(String(format: "  B=%d%@: %.1fms/件（%.1f 倍）1 万件 %.1f 分  cos 差の最大 %.5f  山 footprint %.0fMB resident %.0fMB  慣らし %.1fs  裏で作っている間の検索 中央値 %.0fms 最大 %.0fms",
                     B, b.useBatchProvider ? "（provider）" : "", per, single / per, per * 10000 / 60000, maxDiff, m.footprint, m.resident, warm,
                     dm, during.max() ?? 0))
    }
    let qb = queryMs()
    print(String(format: "検索 1 文（後）: 中央値 %.1fms 最大 %.1fms  footprint %.0fMB resident %.0fMB", qb.0, qb.1, physFootprintMB(), residentMB()))
    exit(0)
}

/// 広い範囲を丸ごと入れてみる（raiden-eval --scope-run --roots ~/Project --file-store <コピー>）。
/// アプリと同じ FileIndex の道筋（一覧 → 短い説明で全部 → 中身ありで作り直し）で、段ごとの時間・メモリ・DB の大きさ・検索の時間を出す。
/// 本物の settings.json と raiden.sqlite には触らない（--file-store はコピーを渡す）。ユーザーのファイルは読むだけ
func runScopeRun(embedder: Embedder) throws {
    guard let sp = opt("--file-store"), sp != Store.defaultURL.path else { print("--file-store <コピー> を渡してください"); return }
    let roots = (opt("--roots") ?? "~/Project").split(separator: ",").map { String($0) }
    let scope = ScanScope(roots: roots)
    let store = try Store(url: URL(fileURLWithPath: sp))
    let e = Engine(embedder: CachedEmbedder(embedder), store: store)
    let idx = FileIndex(engine: e, scope: scope)
    idx.background = true
    let meter = PeakMeter(); meter.start()
    let fp0 = physFootprintMB(), rs0 = residentMB()
    var t = Date()
    idx.fullScan()
    let tList = Date().timeIntervalSince(t)
    print(String(format: "一覧 %d 件 %.1fs（短い説明で作る %d 件・中身ありで作り直す %d 件）footprint %.0f→%.0fMB resident %.0f→%.0fMB",
                 e.files.count, tList, idx.shortTotal, idx.fullTotal, fp0, physFootprintMB(), rs0, residentMB()))
    func searchMs() -> String {
        let qs = ["請求書のPDF", "先週のスクショ", "README", "Unity のシーン", "設計書"]
        var ts: [Double] = []
        for q in qs { let t1 = Date(); _ = e.searchFilesJudged(q, limit: 9); ts.append(Date().timeIntervalSince(t1) * 1000) }
        return qs.indices.map { String(format: "%@ %.0fms", qs[$0], ts[$0]) }.joined(separator: " / ")
    }
    print("  検索（ベクトル化の前）: " + searchMs())
    t = Date()
    var last = Date()
    while idx.shortDone < idx.shortTotal {
        idx.embedStep(count: 256)
        if Date().timeIntervalSince(last) > 60 {
            last = Date()
            FileHandle.standardError.write("  短い説明 \(idx.shortDone)/\(idx.shortTotal) \(Int(Date().timeIntervalSince(t)))s\n".data(using: .utf8)!)
        }
    }
    let tShort = Date().timeIntervalSince(t)
    print(String(format: "短い説明 %d 件 %.0fs（%.1fms/件）footprint %.0fMB resident %.0fMB", idx.shortTotal, tShort,
                 tShort * 1000 / Double(max(idx.shortTotal, 1)), physFootprintMB(), residentMB()))
    print("  検索（短い説明のあと）: " + searchMs())
    t = Date()
    while idx.hasPending {
        idx.embedStep(count: 256)
        if Date().timeIntervalSince(last) > 60 {
            last = Date()
            FileHandle.standardError.write("  中身あり \(idx.fullDone)/\(idx.fullTotal) \(Int(Date().timeIntervalSince(t)))s\n".data(using: .utf8)!)
        }
    }
    let tFull = Date().timeIntervalSince(t)
    meter.stop()
    print(String(format: "中身あり %d 件 %.0fs（%.1fms/件）footprint %.0fMB resident %.0fMB  山 footprint %.0fMB resident %.0fMB", idx.fullTotal, tFull,
                 tFull * 1000 / Double(max(idx.fullTotal, 1)), physFootprintMB(), residentMB(), meter.footprint, meter.resident))
    print("  検索（全部のあと）: " + searchMs())
    // DB の大きさ（WAL を書き戻してから）
    _ = try? Store(url: URL(fileURLWithPath: sp))
    let size = (try? FileManager.default.attributesOfItem(atPath: sp)[.size] as? Int) ?? 0
    let wal = (try? FileManager.default.attributesOfItem(atPath: sp + "-wal")[.size] as? Int) ?? 0
    print(String(format: "DB %.1fMB（WAL %.1fMB）点 file %d folder %d", Double(size) / 1_048_576, Double(wal) / 1_048_576,
                 store.count(kind: "file"), store.count(kind: "folder")))
    print(String(format: "合計 %.0f 分（一覧 %.0fs＋短い説明 %.0fs＋中身あり %.0fs）", (tList + tShort + tFull) / 60, tList, tShort, tFull))
}

/// 2 値のベクトルの近さの計算だけの速さとメモリ（raiden-eval --bench-binary 1200,270000,1140000）。中身は乱数
func runBenchBinary() {
    let ns = (opt("--bench-binary") ?? "1200,270000,1140000").split(separator: ",").compactMap { Int($0) }
    var q = (0..<1024).map { _ in Float.random(in: -1...1) }
    q = Vec.normalized(q)
    for n in ns {
        let fp0 = physFootprintMB()
        var codes = [UInt8](repeating: 0, count: n * BinVec.bytes)
        for i in codes.indices { codes[i] = UInt8.random(in: 0...255) }
        for mode in [BinVec.Mode.asym, .hamming] {
            BinVec.mode = mode
            var ts: [Double] = []
            for _ in 0..<5 { let t = Date(); _ = BinVec.scores(codes: codes, n: n, query: q); ts.append(Date().timeIntervalSince(t) * 1000) }
            ts.sort()
            print(String(format: "  %8d 件 %@: 中央 %.1fms  2 値のベクトル %.1fMB（footprint +%.0fMB）", n, mode.rawValue, ts[2],
                         Double(codes.count) / 1_048_576, physFootprintMB() - fp0))
        }
    }
    exit(0)
}
