// ファイル・フォルダの答え合わせと、V / K / G の組み合わせ比べ。
//
//   raiden-eval --files [--list] [--evals <dir>] [--miss] [--quick]
//
// 問題と例は私的なファイル名を含むので、リポジトリには置かず ~/Library/Application Support/Raiden/evals/ に置く。
//   files.json          [{"q": 言い方, "gold": [~/ からのパス...], "cat": 種類}]   cat: file folder time type relation partial english none
//   file-examples.json  [{"q": 言い方, "path": ~/ からのパス}]   k近傍法の「過去に選んだ例」（files.json の言い方とは別）
import Foundation
import RaidenCore

struct FQ: Decodable { let q: String; let gold: [String]; let cat: String }
struct FEx: Decodable { let q: String; let path: String }

let home = NSHomeDirectory()
func abs(_ p: String) -> String { (p.hasPrefix("/") ? p : home + "/" + p).precomposedStringWithCanonicalMapping }
/// 答え合わせの基準日（問題は 2026-11-19 に作った。--now YYYY-MM-DD で変える）
let evalNow: Date = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    return f.date(from: (opt("--now") ?? "2026-11-19") + " 12:00")!
}()
func f1(_ x: Double) -> String { String(format: "%.1f", x) }

struct Score {
    var h1 = 0, h3 = 0, h5 = 0, n = 0
    var ms: [Double] = []
    var misses: [String] = []
    var top1Scores: [Float] = []
    mutating func add(_ o: Score) { h1 += o.h1; h3 += o.h3; h5 += o.h5; n += o.n; ms += o.ms; misses += o.misses; top1Scores += o.top1Scores }
    var cell: String { "\(h1)/\(h3)/\(h5)" }
}

/// 1 問ずつの入力（ベクトルは作り済み）
struct Prepared {
    let q: String; let vec: [Float]; let restVec: [Float]?; let intent: QueryIntent; let gold: Set<String>; let cat: String
    let rel: (anchor: [Float], target: [Float])?
}

func evalFiles(_ e: Engine, _ qs: [Prepared], _ m: Mix, useRest: Bool = false) -> [String: Score] {
    var out: [String: Score] = [:]
    for p in qs {
        let t = Date()
        let v = (useRest ? p.restVec : nil) ?? p.vec
        let top = e.rankFiles(query: p.q, vec: v, mix: m, intent: p.intent, rel: p.rel, limit: 5)
        var s = Score()
        s.ms.append(Date().timeIntervalSince(t) * 1000)
        s.n = 1
        s.top1Scores.append(top.first?.score ?? 0)
        if p.cat != "none" {
            let paths = top.map(\.file.path)
            if let f = paths.first, p.gold.contains(f) { s.h1 = 1 }
            if paths.prefix(3).contains(where: p.gold.contains) { s.h3 = 1 }
            if paths.contains(where: p.gold.contains) { s.h5 = 1 }
            if s.h1 == 0 {
                s.misses.append("    [\(p.cat)] \(p.q) -> " + paths.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: " | "))
            }
        }
        out[p.cat, default: Score()].add(s)
    }
    return out
}

func evalApps(_ e: Engine, _ qs: [(String, [String], [Float])], _ m: Mix) -> Score {
    var s = Score()
    for (q, gold, v) in qs {
        let t = Date()
        let top = e.rankApps(query: q, vec: v, mix: m, limit: 5).map(\.app.jp)
        s.ms.append(Date().timeIntervalSince(t) * 1000)
        s.n += 1
        if let f = top.first, gold.contains(f) { s.h1 += 1 } else { s.misses.append("    \(q) -> \(top.prefix(3))") }
        if top.prefix(3).contains(where: gold.contains) { s.h3 += 1 }
        if top.contains(where: gold.contains) { s.h5 += 1 }
    }
    return s
}

func med(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.sorted()[xs.count / 2] }

/// 比べる組み合わせ（V / K / G の 7 通り × 和 / RRF）。G のたどり方は別に振る
func combos(_ base: Mix) -> [Mix] {
    var out: [Mix] = []
    for (v, k, g) in [(true, false, false), (false, true, false), (false, false, true), (true, true, false),
                      (true, false, true), (false, true, true), (true, true, true)] {
        for f in [Mix.Fusion.sum, .rrf] {
            var m = base
            m.v = v; m.k = k; m.g = g; m.fusion = f
            out.append(m)
        }
    }
    return out
}

func runFileEval(embedder: Embedder, appQs: [(String, [String])], appEngine: Engine) throws {
    let evalDir = opt("--evals") ?? RaidenPaths.support.appendingPathComponent("evals").path
    let fp0 = physFootprintMB()
    var t = Date()
    let entries = FileCatalog.collect()
    let tList = Date().timeIntervalSince(t)
    if args.contains("--list") {
        let df = ISO8601DateFormatter()
        func d(_ x: Int) -> String { x > 0 ? String(df.string(from: Date(timeIntervalSince1970: TimeInterval(x))).prefix(16)) : "-" }
        for e in entries {
            print("\(e.path.replacingOccurrences(of: home + "/", with: ""))\t\(e.kind)\t\(e.families.joined(separator: ","))\tm=\(d(e.mtime)) add=\(d(e.added)) used=\(d(e.lastUsed))\(e.downloaded ? " DL" : "")")
        }
        return
    }
    // --file-store <path>: 説明文を試すときにアプリの SQLite を書き換えないよう、別のファイルを使う
    let store = try opt("--file-store").map { try Store(url: URL(fileURLWithPath: $0)) } ?? Store()
    let e = Engine(embedder: embedder, store: store)
    t = Date()
    let made = e.setFiles(entries) { n, total in if n % 100 == 0 || n == total { FileHandle.standardError.write("  ベクトル化 \(n)/\(total) 件\n".data(using: .utf8)!) } }
    let tVec = Date().timeIntervalSince(t)
    let ec = e.fileEdgeCounts
    print("ファイル \(entries.filter { !$0.isDir }.count) 件・フォルダ \(entries.filter(\.isDir).count) 件（一覧 \(f1(tList * 1000))ms）")
    print("ベクトル化 \(made) 件 \(f1(tVec))s（作り直しが 0 件なら SQLite から読んだだけ）  線 contains \(ec.contains) / co_used \(ec.coUsed) / co_time \(ec.coTime)")
    print("メモリ footprint \(String(format: "%.0f", physFootprintMB()))MB（読み込み前 \(String(format: "%.0f", fp0))MB）/ resident \(String(format: "%.0f", residentMB()))MB")

    // files.json と parts/*.json（担当ごとの問題）をつなぐ。例は file-examples.json と parts/file-examples.json
    let fm = FileManager.default
    var qFiles = [evalDir + "/files.json"], exFiles = [evalDir + "/file-examples.json"]
    for f in ((try? fm.contentsOfDirectory(atPath: evalDir + "/parts")) ?? []).sorted() where f.hasSuffix(".json") {
        if f.contains("example") { exFiles.append(evalDir + "/parts/" + f) } else { qFiles.append(evalDir + "/parts/" + f) }
    }
    var raw0: [FQ] = [], exs0: [FEx] = []
    for f in qFiles where fm.fileExists(atPath: f) {
        do { raw0 += try JSONDecoder().decode([FQ].self, from: Data(contentsOf: URL(fileURLWithPath: f))) }
        catch { print("  ※ 読めない: \(f) \(error)") }
    }
    for f in exFiles where fm.fileExists(atPath: f) {
        do { exs0 += try JSONDecoder().decode([FEx].self, from: Data(contentsOf: URL(fileURLWithPath: f))) }
        catch { print("  ※ 読めない: \(f) \(error)") }
    }
    let live = Set(entries.map(\.path))
    // 答えが一覧に無い問題は除く（除外条件の違い）。答えの一部だけ無いなら、ある分だけで数える
    var raw: [FQ] = []
    var dropped = 0
    for q in raw0 {
        let g = q.gold.filter { live.contains(abs($0)) }
        if q.cat != "none" && g.isEmpty { dropped += 1; print("  ※ 答えが一覧に無いので除く: [\(q.cat)] \(q.q)"); continue }
        raw.append(FQ(q: q.q, gold: g, cat: q.cat))
    }
    let exs = exs0.filter { live.contains(abs($0.path)) }
    let qTexts = Set(raw.map(\.q))
    let leaked = exs.filter { qTexts.contains($0.q) }.count
    if dropped > 0 || leaked > 0 { print("  除いた問題 \(dropped) 問 / 問題と同じ言い方の例 \(leaked) 個") }
    t = Date()
    let qs = raw.map { q -> Prepared in
        let it = QueryIntent.parse(q.q, now: evalNow)
        return Prepared(q: q.q, vec: embedder.embed(q.q), restVec: it.rest.isEmpty || it.rest == q.q ? nil : embedder.embed(it.rest),
                        intent: it, gold: Set(q.gold.map(abs)), cat: q.cat,
                        rel: it.hasRelation ? (embedder.embed(it.anchor), embedder.embed(it.target.isEmpty ? q.q : it.target)) : nil)
    }
    let embedMs = Date().timeIntervalSince(t) * 1000 / Double(raw.count + qs.filter { $0.restVec != nil }.count)
    let appPrepared = appQs.map { ($0.0, $0.1, embedder.embed($0.0)) }
    let cats = ["file", "folder", "time", "type", "relation", "partial", "english"]
    var catCount: [String: Int] = [:]
    for q in raw { catCount[q.cat, default: 0] += 1 }
    print("問題 \(raw.count) 問 " + (cats + ["none"]).map { "\($0) \(catCount[$0] ?? 0)" }.joined(separator: " ") + "  例 \(exs.count) 個  入力のベクトル化 \(f1(embedMs))ms/回")

    // 例の数: 0 / 少し（3 個に 1 個）/ 全部
    let exLevels: [(String, [FEx])] = [("例0", []), ("例少し", exs.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)), ("例全部", exs)]
    func setExamples(_ xs: [FEx]) { e.clearFileExamples(); e.addFileExamples(xs.map { ($0.q, abs($0.path)) }) }

    func header() -> String { "  " + "組み合わせ".padding(toLength: 34, withPad: " ", startingAt: 0) + cats.map { $0.padding(toLength: 9, withPad: " ", startingAt: 0) }.joined() + "全体(1/3/5)   1回ms  アプリ(1/3/5)" }
    func line(_ m: Mix, _ r: [String: Score], _ app: Score?) -> (String, Score) {
        var all = Score()
        for c in cats { if let s = r[c] { all.add(s) } }
        let cells = cats.map { (r[$0]?.cell ?? "-").padding(toLength: 9, withPad: " ", startingAt: 0) }.joined()
        let a = app.map { $0.cell } ?? ""
        return ("  " + m.description.padding(toLength: 34, withPad: " ", startingAt: 0) + cells + all.cell.padding(toLength: 13, withPad: " ", startingAt: 0)
                + f1(med(all.ms) + embedMs).padding(toLength: 7, withPad: " ", startingAt: 0) + a, all)
    }

    var best: (Mix, Int) = (Mix.fileDefault, -1)
    func scoreOf(_ r: [String: Score]) -> Int {
        var all = Score(); for c in cats { if let x = r[c] { all.add(x) } }
        return all.h1 * 100 + all.h3 * 10 + all.h5
    }
    let quick = args.contains("--quick")
    let secs = Set((opt("--section") ?? "all").split(separator: ",").map(String.init))
    func on(_ x: String) -> Bool { secs.contains("all") || secs.contains(x) }
    // 節を飛ばしたときは Mix.fileDefault の値を使う（並列で節ごとに回すため）
    var kBest = Mix.fileDefault
    var gBase = Mix.fileDefault
    var gBest = Mix.fileDefault; gBest.g = true; gBest.relation = false
    var vOnly = Mix.fileDefault; vOnly.k = false; vOnly.g = false; vOnly.relation = false
    var relBest = Mix.fileDefault; relBest.k = false
    var fBest = Mix.fileDefault
    let edgeSets: [(String, Bool, Bool, Bool, Bool)] = [
        ("contains↓", true, false, false, false), ("contains↓↑", true, false, false, true), ("co_used", false, true, false, false),
        ("co_time", false, false, true, false), ("contains↓+co_used+co_time", true, true, true, false), ("全部↓↑", true, true, true, true)]

    if on("k") {
    // 1) K の効かせ方（V+K 和）。例が一部の点にしか無いと、近い例の点だけが飛び抜ける。重みと「これより遠い例は数えない」を振る
    print("\n== K の効かせ方（V+K 和・絞り込みあり）。例0 / 例少し / 例全部 の 全体 1位/3位/5位")
    var kBestScore = -1
    for w in [Float(1), 0.5, 0.3] {
        for ms in [Float(0), 0.5, 0.6, 0.7] {
            var m = Mix.fileDefault; m.v = true; m.k = true; m.wK = w; m.knnMinSim = ms
            var cellsOut: [String] = []
            var tot = 0
            for (_, xs) in exLevels {
                setExamples(xs)
                let r = evalFiles(e, qs, m)
                var all = Score(); for c in cats { if let x = r[c] { all.add(x) } }
                cellsOut.append(all.cell); tot += scoreOf(r)
            }
            print("  wK=\(w) 最低の近さ=\(ms): " + cellsOut.joined(separator: "  "))
            if tot > kBestScore { kBestScore = tot; kBest = m }
        }
    }
    print("  採用: wK=\(kBest.wK) 最低の近さ=\(kBest.knnMinSim)")

    }
    if on("g") {
    // 2) G のたどり方（V+G 和、例0）。線の種類ごとに一番よかった N・α・回数
    setExamples([])
    print("\n== G のたどり方（V+G 和・例0・絞り込みあり） 各セルは 1位/3位以内/5位以内")
    print(header())
    gBase.v = true; gBase.k = false; gBase.g = true
    var gBestScore = -1
    let ns = quick ? [10] : [3, 5, 10, 20]
    let alphas: [Float] = quick ? [0.5] : [0.2, 0.35, 0.5, 0.7]
    for (name, c, co, ct, up) in edgeSets {
        var best: (Mix, Int, [String: Score])? = nil
        for hops in [1, 2] { for n in ns { for a in alphas {
            var m = gBase
            m.seeds = n; m.alpha = a; m.hops = hops; m.contains = c; m.coUsed = co; m.coTime = ct; m.up = up
            let r = evalFiles(e, qs, m)
            let sc = scoreOf(r)
            if best == nil || sc > best!.1 { best = (m, sc, r) }
        } } }
        print(line(best!.0, best!.2, nil).0 + "  " + name + " の一番")
        if best!.1 > gBestScore { gBestScore = best!.1; gBest = best!.0 }
    }
    vOnly = gBase; vOnly.g = false
    print(line(vOnly, evalFiles(e, qs, vOnly), nil).0 + "  ← 比較: V だけ")
    print("  一番よかったたどり方: \(gBest.description)")

    }
    if on("rel") {
    // 3) つながりの言い方を分けて、anchor から線をたどる（relation の問題向け）
    print("\n== つながりの言い方の分割（「A と同じ日の B」「A の中の B」→ A で入口、線をたどって B との近さで並べる。例0）")
    print(header())
    let relQs = qs.filter { $0.rel != nil }
    print("  つながりの言い方と読めた問題 \(relQs.count) 問（うち relation \(relQs.filter { $0.cat == "relation" }.count) 問）")
    relBest = vOnly
    var relBestScore = scoreOf(evalFiles(e, qs, vOnly))
    for (name, c, co, ct, _) in edgeSets where name != "contains↓↑" && name != "全部↓↑" {
        for hops in [1, 2] { for ra in [Float(0.5), 1.0, 1.5, 2.0] { for wt in [Float(0.3), 0.5, 1.0] { for n in [3, 5, 10] {
            var m = vOnly
            m.relation = true; m.relAlpha = ra; m.relWT = wt; m.seeds = n; m.hops = hops
            m.contains = c; m.coUsed = co; m.coTime = ct
            let r = evalFiles(e, qs, m)
            let sc = scoreOf(r)
            if sc > relBestScore { relBestScore = sc; relBest = m }
        } } } }
    }
    var relOff = relBest; relOff.relation = false
    print(line(relOff, evalFiles(e, qs, relOff), nil).0 + "  ← 比較: 分割しない")
    print(line(relBest, evalFiles(e, qs, relBest), nil).0 + "  一番（N=\(relBest.seeds) 回=\(relBest.hops) c=\(relBest.contains) co=\(relBest.coUsed) ct=\(relBest.coTime)）")
    for (name, c, co, ct, _) in edgeSets where name != "contains↓↑" && name != "全部↓↑" {
        var m = relBest; m.contains = c; m.coUsed = co; m.coTime = ct
        print(line(m, evalFiles(e, qs, m), nil).0 + "  線を \(name) にした場合")
    }
    for ct in [false, true] { for ra in [Float(0.5), 1.0] {
        var m = relBest; m.relByKind = true; m.coTime = ct; m.relAlpha = ra
        print(line(m, evalFiles(e, qs, m), nil).0 + "  「の中の」は contains↓、「同じ日」は co_used\(ct ? "+co_time" : "")")
    } }

    }
    if on("folder") {
    // 4) フォルダの加点
    print("\n== 「〜のとこ」「フォルダ」でフォルダを上げる量（例0）")
    print(header())
    fBest = relBest; var fBestScore = -1
    for fb in [Float(0), 0.15, 0.3, 0.5] {
        var m = relBest; m.folderBonus = fb
        let r = evalFiles(e, qs, m)
        print(line(m, r, nil).0 + "  フォルダ加点 \(fb)")
        if scoreOf(r) > fBestScore { fBestScore = scoreOf(r); fBest = m }
    }

    }
    if on("combos") {
    // 5) 7 通り × 和 / RRF × 例の数（K・G・つながり・フォルダは上で決めた値）
    for (lvName, xs) in exLevels {
        setExamples(xs)
        print("\n== 組み合わせ（\(lvName) \(xs.count) 個）")
        print(header())
        for rel in [false, true] {
            for m0 in combos(gBest) {
                var m = m0
                m.wK = kBest.wK; m.knnMinSim = kBest.knnMinSim; m.folderBonus = fBest.folderBonus
                m.relation = rel; m.relAlpha = relBest.relAlpha; m.relWT = relBest.relWT
                if rel { m.contains = relBest.contains; m.coUsed = relBest.coUsed; m.coTime = relBest.coTime }
                if rel && (m0.g == false) { m.seeds = relBest.seeds; m.hops = relBest.hops }
                if rel && !m0.v { continue }  // つながり分割は V を使う組み合わせだけ（anchor をベクトルで探す）
                let r = evalFiles(e, qs, m)
                let app = evalApps(appEngine, appPrepared, appMixFor(m0))
                let (l, all) = line(m, r, app)
                print(l)
                let sc = all.h1 * 100 + all.h3 * 10 + all.h5
                if lvName == "例0" && sc > best.1 { best = (m, sc) }
            }
        }
    }
    print("  例0 で一番: \(best.0.description)")

    }
    if on("intent") {
    // 3) 絞り込み（時間・種類）の効き。例0、一番よかった組み合わせで
    setExamples([])
    print("\n== 時間・種類の言葉の読み取り（\(best.0.label) \(best.0.fusion.rawValue)・例0）")
    print(header())
    for (name, f) in [("絞り込みなし", { (m: inout Mix) in m.intents = false }),
                      ("絞り込みあり（範囲外を下げる）", { (m: inout Mix) in m.intents = true; m.timeFilter = true }),
                      ("絞り込みあり（範囲内を上げるだけ）", { (m: inout Mix) in m.intents = true; m.timeFilter = false }),
                      ("種類の加点 0.3", { (m: inout Mix) in m.intents = true; m.typeBonus = 0.3 })] {
        var m = best.0
        f(&m)
        print(line(m, evalFiles(e, qs, m), nil).0 + "  " + name)
    }
    var mr = best.0
    print(line(mr, evalFiles(e, qs, mr, useRest: true), nil).0 + "  時間・種類の言葉を抜いた残りでベクトル")
    mr.fuzzyBonus = 0
    print(line(mr, evalFiles(e, qs, mr), nil).0 + "  ローマ字・打ち間違いの一致なし")

    }
    if on("switch") {
    // 4) 入力の形で切り替え（時間・種類の言葉があれば V を弱めて絞り込みを強める / 英数字だけなら文字一致を強める）
    print("\n== 入力の形で重みを切り替える（例0）")
    print(header())
    for (wv, tb) in [(Float(1), Float(0.15)), (0.7, 0.3), (0.5, 0.4)] {
        var r: [String: Score] = [:]
        for p in qs {
            var m = best.0
            if !p.intent.isEmpty { m.wV = wv; m.typeBonus = tb; m.timeBonus = tb * 2 }
            if p.q.allSatisfy({ $0.isASCII }) { m.fuzzyBonus = 0.5; m.prefixBonus = 0.8 }
            for (c, s) in evalFiles(e, [p], m) { r[c, default: Score()].add(s) }
        }
        var lbl = best.0; lbl.wV = wv
        print(line(lbl, r, nil).0 + "  時間/種類ありは wV=\(wv) 加点=\(tb)、英数字だけは文字一致を強く")
    }

    }
    if on("final") {
    // 最終: Engine に入れた既定（Mix.fileDefault）を例の数ごとに。アプリ 25 問は Engine.search（appDefault）で
    print("\n== 最終（Mix.fileDefault = \(Mix.fileDefault.description)）")
    print(header())
    for (lvName, xs) in exLevels {
        setExamples(xs)
        print(line(Mix.fileDefault, evalFiles(e, qs, Mix.fileDefault), nil).0 + "  " + lvName)
    }
    // 変種: つながり以外の入力では V+G（contains↓）も足す
    for (n, a, h) in [(3, Float(0.2), 1), (5, 0.2, 1), (3, 0.35, 1), (5, 0.2, 2)] {
        var mg = Mix.fileDefault
        mg.g = true; mg.seeds = n; mg.alpha = a; mg.hops = h; mg.up = false
        mg.contains = true; mg.coUsed = false; mg.coTime = false
        mg.relEdges = (false, true, false); mg.relWT = Mix.fileDefault.relWT; mg.relAlpha = Mix.fileDefault.relAlpha
        for (lvName, xs) in exLevels {
            setExamples(xs)
            print(line(mg, evalFiles(e, qs, mg), nil).0 + "  " + lvName + "（つながりは co_used で分割のまま）")
        }
    }
    var h1 = 0, h3 = 0
    for (q, gold) in appQs {
        let top = appEngine.search(q, limit: 3).map(\.app.jp)
        if let f = top.first, gold.contains(f) { h1 += 1 }
        if top.contains(where: gold.contains) { h3 += 1 }
    }
    print("  アプリ 25 問（Engine.search）: 1位 \(h1)/\(appQs.count) 3位以内 \(h3)/\(appQs.count)")
    setExamples([])
    let rf = evalFiles(e, qs, Mix.fileDefault)
    print("  外れ（例0）:")
    for c in cats { rf[c]?.misses.forEach { print($0) } }
    }
    if on("fold") {
    // フォルダの点数の付け方を比べる（Mix.fileDefault からの変更。例0 と 例全部）
    print("\n== フォルダの点数（例0 / 例全部）")
    print(header())
    var vars: [(String, (inout Mix) -> Void)] = [("今の既定", { _ in })]
    vars.append(("中の種類の加点なし", { $0.folderTypeBonus = 0 }))
    vars.append(("子がそろって上位の加点なし", { $0.folderCrowd = 0 }))
    vars.append(("空のフォルダにも加点", { $0.emptyFolderBonus = true }))
    vars.append(("時間はフォルダ自身の日付だけ", { $0.folderTimeByChildren = false }))
    vars.append(("フォルダの言葉がどこにあっても加点", { $0.folderHeadOnly = false }))
    vars.append(("フォルダの扱いを全部前のまま", { $0.folderTypeBonus = 0; $0.folderCrowd = 0; $0.emptyFolderBonus = true; $0.folderTimeByChildren = false; $0.folderHeadOnly = false }))
    if let extra = opt("--fold-only") { let keep = Set(extra.split(separator: ",").compactMap { Int($0) }); vars = vars.enumerated().filter { keep.contains($0.offset) }.map(\.element) }
    for (name, f) in vars {
        var m = Mix.fileDefault; f(&m)
        setExamples([])
        let r0 = evalFiles(e, qs, m)
        setExamples(exs)
        let (_, allA) = line(m, evalFiles(e, qs, m), nil)
        print(line(m, r0, nil).0 + "  例全部 \(allA.cell)  " + name)
        if args.contains("--miss") { for c in cats { r0[c]?.misses.forEach { print($0) } } }
    }
    setExamples([])
    }
    if on("folddbg") {
    // フォルダの問題で、答えが何位にいて点数がいくつか（例0・Mix.fileDefault）
    setExamples([])
    print("\n== フォルダの問題の順位（例0）")
    for p in qs where p.cat == "folder" {
        let top = e.rankFiles(query: p.q, vec: p.vec, mix: Mix.fileDefault, intent: p.intent, rel: p.rel, limit: 40)
        let gi = top.firstIndex { p.gold.contains($0.file.path) }
        let fmt: (FileResult) -> String = { String(format: "%@ %.3f", ($0.file.path as NSString).lastPathComponent, $0.score) }
        print("  \(gi.map { "\($0 + 1)位" } ?? "40位外") \(p.q)  [\(p.intent.families.sorted().joined(separator: ","))]")
        print("      " + top.prefix(3).map(fmt).joined(separator: " | ") + (gi.map { $0 >= 3 ? "  … 答え " + fmt(top[$0]) : "" } ?? ""))
    }
    }
    if on("misc") {
    // 5) 外れた問題（一番よかった組み合わせ・例0）
    setExamples([])
    let rBest = evalFiles(e, qs, best.0)
    print("\n== 外れ（\(best.0.description)・例0）")
    for c in cats { rBest[c]?.misses.forEach { print($0) } }

    }
    if on("misc") {
    // 6) 答えが無い入力: 1 位の点数のしきい値で「見つからない」を出せるか
    print("\n== 答えが無い・曖昧すぎる入力（\(best.0.description)・例0）")
    setExamples([])
    let rBest = evalFiles(e, qs, best.0)
    let noneScores = rBest["none"]?.top1Scores ?? []
    var okScores: [Float] = []
    for c in cats { okScores += rBest[c]?.top1Scores ?? [] }
    for p in qs where p.cat == "none" {
        let top = e.rankFiles(query: p.q, vec: p.vec, mix: best.0, intent: p.intent, limit: 1)
        print("    \(p.q) -> \(top.first.map { ($0.file.path as NSString).lastPathComponent } ?? "-")  点数 \(String(format: "%.3f", top.first?.score ?? 0))")
    }
    for th in stride(from: Float(0.40), through: 0.70, by: 0.025) {
        let rejNone = noneScores.filter { $0 < th }.count
        let keepOk = okScores.filter { $0 >= th }.count
        print(String(format: "    しきい値 %.3f: 答え無しを「見つからない」にできた %d/%d  答えがある問題で候補を出した %d/%d", th, rejNone, noneScores.count, keepOk, okScores.count))
    }

    }
    if on("nomatch") {
    // 9) 「見つからない」の判定（NoMatchRule）。手がかりを --dump-signals <file> に TSV で書き出し、
    //    いまの既定（.files / .apps）で答え無しを弾けた数と、答えのある問題を誤って弾いた数を出す。
    //    parts/none2.json は判定を決めた後に作った答え無しの問題（当てはまりすぎの確かめ用）なので別に数える。
    let held = Set(((try? JSONDecoder().decode([FQ].self, from: Data(contentsOf: URL(fileURLWithPath: evalDir + "/parts/none2.json")))) ?? []).map(\.q))
    var tsv = ["set\tcat\tsrc\thit1\tq\ttop1\ttop2\trawV\tmaxV\tvZ\tknnSim\tnameHit\tintent\trelation\tvGap\tgap0"]
    func row(_ set: String, _ cat: String, _ src: String, _ hit: Bool, _ q: String, _ s: MatchSignals) -> String {
        [set, cat, src, hit ? "1" : "0", q, String(s.top1), String(s.top2), String(s.rawV), String(s.maxV), String(s.vZ),
         String(s.knnSim), s.nameHit ? "1" : "0", s.hasIntent ? "1" : "0", s.relation ? "1" : "0", String(s.vGap), String(s.gapNoEx)].joined(separator: "\t")
    }
    let fr = NoMatchRule.files, ar = NoMatchRule.apps
    print("\n== 「見つからない」の判定（ファイル: maxV<\(fr.lowMaxV) か maxV<\(fr.midMaxV)・差<\(fr.maxGap)、例≥\(fr.keepKnnSim) は残す / アプリ: maxV<\(ar.lowMaxV)、例≥\(ar.keepKnnSim) は残す）")
    for (lvName, xs) in exLevels where lvName != "例少し" {
        setExamples(xs)
        var rejNone = 0, nNone = 0, rejHeld = 0, nHeld = 0, rejOk = 0, nOk = 0, keep1 = 0, keep3 = 0
        var wrong: [String] = []
        for p in qs {
            let j = e.rankFilesJudged(query: p.q, vec: p.vec, mix: Mix.fileDefault, intent: p.intent, rel: p.rel, limit: 5)
            let paths = j.results.map(\.file.path)
            let hit = paths.first.map(p.gold.contains) ?? false
            let src = held.contains(p.q) ? "none2" : (p.cat == "none" ? "none" : "ok")
            tsv.append(row(lvName, p.cat, src, hit, p.q, j.signals))
            if p.cat == "none" {
                if src == "none2" { nHeld += 1; if j.noMatch { rejHeld += 1 } else { wrong.append("    残った[none2] \(p.q)  \(j.signals)") } }
                else { nNone += 1; if j.noMatch { rejNone += 1 } else { wrong.append("    残った[none] \(p.q)  \(j.signals)") } }
            } else {
                nOk += 1
                if j.noMatch { rejOk += 1; wrong.append("    弾いた[\(p.cat)]\(hit ? "（1位は正解）" : "") \(p.q)  \(j.signals)") }
                if hit { keep1 += 1 }
                if paths.prefix(3).contains(where: p.gold.contains) { keep3 += 1 }
            }
        }
        print("  \(lvName): 答え無し \(rejNone)/\(nNone) を弾いた  作った答え無し \(rejHeld)/\(nHeld)  答えのある問題を誤って弾いた \(rejOk)/\(nOk)  （1位 \(keep1) 3位以内 \(keep3)）")
        if args.contains("--miss") { wrong.forEach { print($0) } }
    }
    setExamples([])
    for (name, list) in [("アプリ25問", appQs), ("アプリ名前の一部", PARTIAL)] {
        var rej = 0
        for (q, gold) in list {
            let j = appEngine.searchJudged(q, limit: 3)
            let hit = j.results.first.map { gold.contains($0.app.jp) } ?? false
            tsv.append(row(name, "app", "ok", hit, q, j.signals))
            if j.noMatch { rej += 1; print("    弾いた[\(name)] \(q)  \(j.signals)") }
        }
        print("  \(name): 誤って弾いた \(rej)/\(list.count)")
    }
    // アプリ側で答え無しの入力（ファイルの答え無しの問題をそのままアプリに入れる）
    var rejA = 0, nA = 0
    for p in qs where p.cat == "none" && !held.contains(p.q) {
        let j = appEngine.searchJudged(p.q, limit: 3)
        tsv.append(row("アプリ答え無し", "none", "none", false, p.q, j.signals))
        nA += 1; if j.noMatch { rejA += 1 }
    }
    print("  アプリに答え無しの入力: 弾いた \(rejA)/\(nA)（参考）")
    if let out = opt("--dump-signals") { try? tsv.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8); print("  手がかり → \(out)") }
    }
    if on("misc") {
    // 7) 1 文字ずつ打つ間の時間
    print("\n== 1 文字ずつ打つ間の時間（埋め込み＋並べ替え、\(best.0.description)）")
    for q in ["請求書のワード", "seikyuusho", "先週ダウンロードしたPDF"] {
        var ts: [String] = []
        for i in 1...q.count {
            let s = String(q.prefix(i))
            let t0 = Date()
            _ = e.rankFiles(query: s, vec: embedder.embed(s), mix: best.0, intent: QueryIntent.parse(s, now: evalNow), limit: 8)
            ts.append(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000))
        }
        print("    \(q): " + ts.joined(separator: " ") + " ms")
    }

    }
    if on("misc") {
    // 8) ファイル数が増えた場合（今のベクトルに揺らぎを足して複製）
    print("\n== ファイル数が増えた場合（並べ替えだけの時間・メモリ。埋め込みは件数に関係なく約 \(f1(embedMs))ms）")
    let base = e.fileCorpusSnapshot
    for mul in [1, 10, 50] {
        let fpB = physFootprintMB()
        var c = Corpus()
        var vecs: [[Float]] = [], names: [[String]] = [], meta: [Corpus.Meta?] = []
        for r in 0..<mul {
            for i in 0..<base.count {
                vecs.append(r == 0 ? base.vecs[i] : Vec.normalized(base.vecs[i].map { $0 + Float.random(in: -0.02...0.02) }))
                names.append(base.names[i].map { $0 + (r == 0 ? "" : "\(r)") })
                meta.append(base.meta[i])
            }
        }
        c.setItems(names: names, vecs: vecs, meta: meta)
        let n0 = base.count
        var ce: [(Int, Int)] = [], co: [(Int, Int, Float)] = []
        for r in 0..<mul {
            for (i, es) in base.adj.enumerated() {
                for x in es where x.kind == 0 { ce.append((r * n0 + i, r * n0 + Int(x.to))) }
                for x in es where x.kind >= 2 && i < Int(x.to) { co.append((r * n0 + i, r * n0 + Int(x.to), x.w)) }
            }
        }
        c.addEdges(contains: ce, coUsed: co)
        var ts: [Double] = []
        for p in qs {
            let t0 = Date()
            _ = Ranker.rank(c, query: p.q, vec: p.vec, mix: best.0, intent: p.intent, limit: 8)
            ts.append(Date().timeIntervalSince(t0) * 1000)
        }
        print(String(format: "    %6d 件: 並べ替え %.1fms（中央値）/ 最大 %.1fms  footprint +%.0fMB（ベクトル Float32 で %.0fMB）",
                     c.count, med(ts), ts.max() ?? 0, physFootprintMB() - fpB, Double(c.count * 1024 * 4) / 1_048_576))
    }
    }
}

/// ファイル側の組み合わせに対応するアプリ側の Mix（たどる線はアプリには chose しか無い）
func appMixFor(_ m: Mix) -> Mix {
    var a = Mix.appDefault
    a.v = m.v; a.k = m.k; a.g = m.g; a.fusion = m.fusion
    a.seeds = m.seeds; a.alpha = m.alpha; a.hops = 1
    return a
}
