// どの演算がどの装置（CPU / GPU / ANE）に載るかを MLComputePlan で数える。
//
//   raiden-eval --plan <body.mlmodelc> [--units ane|all|cpu] [--function b8_s64,…（無ければ meta.json の functions か main）] [--load-time]
//
// 関数ごとに、演算の数と推定の重さ（estimatedCost）で重みづけした ANE の割合、ANE 以外に載った演算の名前を出す。
// tools/convert/ane_plan.py と同じ数え方（const と constexpr_* は数えない）。Python 版は既定の関数しか見られない。
import CoreML
import Foundation

func runAnePlan(_ path: String) async throws {
    let url = URL(fileURLWithPath: path)
    let units: MLComputeUnits = ["cpu": .cpuOnly, "all": .all, "gpu": .cpuAndGPU][opt("--units") ?? ""] ?? .cpuAndNeuralEngine
    var fns = opt("--function")?.split(separator: ",").map(String.init) ?? []
    if fns.isEmpty, let d = try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("meta.json")),
       let meta = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        fns = meta["functions"] as? [String] ?? []
    }
    if fns.isEmpty { fns = ["main"] }
    // --load-time: 関数ごとに MLModel を読む時間（初回は ANE 向けのコンパイル込み。2 回目からは OS のキャッシュ）
    if args.contains("--load-time") {
        for f in fns {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = units
            if f != "main" { cfg.functionName = f }
            let t = Date()
            _ = try MLModel(contentsOf: url, configuration: cfg)
            print(String(format: "[%@] 読み込み %.1fs", f, Date().timeIntervalSince(t)))
        }
        return
    }
    for f in fns {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        if f != "main" { cfg.functionName = f }
        let plan = try await MLComputePlan.load(contentsOf: url, configuration: cfg)
        guard case let .program(prog) = plan.modelStructure else { print("\(f): ML Program ではない"); continue }
        var count: [String: Int] = [:], cost: [String: Double] = [:], off: [String: Int] = [:]
        func walk(_ block: MLModelStructure.Program.Block) {
            for op in block.operations {
                op.blocks.forEach(walk)
                if op.operatorName == "const" || op.operatorName.contains("constexpr") { continue }
                var dev = "none"
                if let u = plan.deviceUsage(for: op) {
                    switch u.preferred {
                    case .neuralEngine: dev = "ANE"
                    case .gpu: dev = "GPU"
                    case .cpu: dev = "CPU"
                    @unknown default: dev = "?"
                    }
                }
                count[dev, default: 0] += 1
                cost[dev, default: 0] += plan.estimatedCost(of: op)?.weight ?? 0
                if dev != "ANE" { off[op.operatorName, default: 0] += 1 }
            }
        }
        for (name, fn) in prog.functions where name == f || (f == "main" && prog.functions.count == 1) { walk(fn.block) }
        let n = count.values.reduce(0, +), w = max(cost.values.reduce(0, +), 1e-12)
        print(String(format: "[%@] 演算 %d  ANE %d（%.1f%%）  推定の重さで ANE %.1f%%  %@", f, n, count["ANE"] ?? 0,
                     100 * Double(count["ANE"] ?? 0) / Double(max(n, 1)), 100 * (cost["ANE"] ?? 0) / w, count.description))
        if !off.isEmpty { print("   ANE 以外: " + off.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
    }
}
