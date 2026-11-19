// ベクトル化の速さとメモリを測る（ファイルの説明文をまとめてベクトル化するときの比べ）。
//
//   raiden-eval --bench-embed [--model-dir <dir>] [--body body.mlmodelc] [--units cpu|ane|gpu|all（無ければ meta.json の units）]
//               [--vs-model-dir <dir> --vs-body <body> --vs-units cpu]
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
    let unitName = opt("--units") ?? "auto"
    let units: MLComputeUnits? = ["cpu": .cpuOnly, "gpu": .cpuAndGPU, "all": .all, "ane": .cpuAndNeuralEngine][unitName]
    let fp0 = physFootprintMB(), rs0 = residentMB()
    let b = try BGEEmbedder(modelDir: dir, body: opt("--body") ?? "body.mlmodelc", computeUnits: units)
    t = Date()
    try b.load()
    if b.aneProgress.total > 0 {
        // ANE は裏で読む。測るのは全部の関数が ANE に載ってから
        let tw = Date()
        let ok = b.waitForANE()
        print(String(format: "ANE の読み込み %@ %.1fs（%d/%d 関数）", ok ? "済み" : "失敗", Date().timeIntervalSince(tw), b.aneProgress.loaded, b.aneProgress.total))
    }
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

    // --vs-model-dir <dir> [--vs-body <body>] [--vs-units cpu]: 別のモデル（今の CPU 版など）と 1 件ずつの結果の cos を比べる
    if let vd = opt("--vs-model-dir") {
        let vb = try BGEEmbedder(modelDir: URL(fileURLWithPath: vd), body: opt("--vs-body") ?? "body.mlmodelc",
                                 computeUnits: ["cpu": .cpuOnly, "ane": .cpuAndNeuralEngine][opt("--vs-units") ?? "cpu"])
        let other = texts.map { vb.embed($0) }
        let d = zip(ref, other).map { Double(1 - Vec.dot($0, $1)) }
        print(String(format: "  別のモデル（%@ %@）との cos 差: 平均 %.5f 最大 %.5f", vd, opt("--vs-body") ?? "body.mlmodelc",
                     d.reduce(0, +) / Double(max(d.count, 1)), d.max() ?? 0))
        vb.unload()
    }

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
