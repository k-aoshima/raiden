// ファイル・フォルダの答え合わせ（Spotlight 版）。
//
//   raiden-eval --files --file-store <scratch の新しいファイル> [--evals <dir>] [--now 2026-11-19] [--miss]
//
// 問題は私的なファイル名を含むので、リポジトリには置かず ~/Library/Application Support/Raiden/evals/ に置く。
//   files.json と parts/*.json（example を含む名前のファイルは除く）  [{"q": 言い方, "gold": [~/ からのパス...], "cat": 種類}]
//   cat: file folder time type relation partial english none（none は答えが無い問題。「見つからない」が立てば当たり）
// アプリと同じ Engine.searchFilesJudged を通す（Mac 全域を Spotlight に問い合わせる。除外は設定の初期値）。「選んだ」記録は使わない。
import Foundation
import RaidenCore

struct FQ: Decodable { let q: String; let gold: [String]; let cat: String }

let home = NSHomeDirectory()
func abs(_ p: String) -> String { (p.hasPrefix("/") ? p : home + "/" + p).precomposedStringWithCanonicalMapping }
/// 答え合わせの基準日（問題は 2026-11-19 に作った。--now YYYY-MM-DD で変える）
let evalNow: Date = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    return f.date(from: (opt("--now") ?? "2026-11-19") + " 12:00")!
}()

func med(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.sorted()[xs.count / 2] }

func loadFileQuestions() -> [FQ] {
    let evalDir = opt("--evals") ?? RaidenPaths.support.appendingPathComponent("evals").path
    let fm = FileManager.default
    var files = [evalDir + "/files.json"]
    for f in ((try? fm.contentsOfDirectory(atPath: evalDir + "/parts")) ?? []).sorted() where f.hasSuffix(".json") && !f.contains("example") {
        files.append(evalDir + "/parts/" + f)
    }
    var out: [FQ] = []
    for f in files where fm.fileExists(atPath: f) {
        do { out += try JSONDecoder().decode([FQ].self, from: Data(contentsOf: URL(fileURLWithPath: f))) }
        catch { print("  ※ 読めない: \(f) \(error)") }
    }
    return out
}

func runFileEval() throws {
    guard let sp = opt("--file-store"), sp != Store.defaultURL.path else { print("--file-store <scratch の新しいファイル> を渡してください"); return }
    let e = Engine(store: try Store(url: URL(fileURLWithPath: sp)), exclude: RaidenSettings().exclude)
    let fm = FileManager.default
    var qs: [FQ] = []
    var dropped = 0
    for q in loadFileQuestions() {
        let g = q.gold.map(abs).filter { fm.fileExists(atPath: $0) }
        if q.cat != "none" && g.isEmpty { dropped += 1; continue }
        qs.append(FQ(q: q.q, gold: g, cat: q.cat))
    }
    print("== ファイルの答え合わせ（Spotlight、\(qs.count) 問、答えのファイルが無くなった \(dropped) 問は除く、基準日 \(opt("--now") ?? "2026-11-19")）")
    struct Row { var n = 0, h1 = 0, h3 = 0, empty = 0; var ms: [Double] = [] }
    var rows: [String: Row] = [:]
    var miss: [String] = []
    var fetched: [Int] = []
    for q in qs {
        let t = Date()
        let j = e.searchFilesJudged(q.q, limit: 5, now: evalNow)
        let ms = Date().timeIntervalSince(t) * 1000
        fetched.append(j.signals.fetched)
        var r = rows[q.cat] ?? Row()
        r.n += 1; r.ms.append(ms)
        if j.noMatch { r.empty += 1 }
        let paths = j.results.map(\.file.path)
        if q.cat == "none" {
            if j.noMatch { r.h1 += 1; r.h3 += 1 } else { miss.append("    [none] \(q.q) -> " + paths.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: " | ")) }
        } else {
            let gold = Set(q.gold)
            if let f = paths.first, gold.contains(f) { r.h1 += 1 }
            if paths.prefix(3).contains(where: gold.contains) { r.h3 += 1 }
            if paths.first.map(gold.contains) != true {
                miss.append("    [\(q.cat)] \(q.q) -> " + (paths.isEmpty ? "（0 件）" : paths.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: " | ")))
            }
        }
        rows[q.cat] = r
    }
    let order = ["file", "folder", "time", "type", "relation", "partial", "english", "none"]
    var all = Row(), allMs: [Double] = []
    print("| 種類 | 問題 | 1位 | 3位以内 | 0 件（見つからない） | 1 回（中央 / 最大） |")
    print("|---|---|---|---|---|---|")
    for c in order + rows.keys.filter({ !order.contains($0) }).sorted() {
        guard let r = rows[c] else { continue }
        print(String(format: "| %@ | %d | %d | %d | %d | %.0fms / %.0fms |", c, r.n, r.h1, r.h3, r.empty, med(r.ms), r.ms.max() ?? 0))
        if c != "none" { all.n += r.n; all.h1 += r.h1; all.h3 += r.h3; all.empty += r.empty }
        allMs += r.ms
    }
    print(String(format: "| 答えのある問題の合計 | %d | %d | %d | %d | %.0fms / %.0fms |", all.n, all.h1, all.h3, all.empty, med(allMs), allMs.max() ?? 0))
    print("Spotlight から受け取った件数（ふるう前） 中央 \(Int(med(fetched.map(Double.init))))・最大 \(fetched.max() ?? 0)")
    if args.contains("--miss") { print("外れ（1 位が正解でない）:"); miss.forEach { print($0) } }
}
