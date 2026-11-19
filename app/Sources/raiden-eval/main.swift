// 答え合わせ。アプリと同じ Engine.search で 25 個の曖昧な言い方を並べ、1位・3位以内の数を出す。
//
//   raiden-eval --model-dir <dir> --body body_int8.mlmodelc [--units ane|cpu|gpu|all] [--sweep] [--reload]
//   raiden-eval --nl     （参考: OS の NLContextualEmbedding）
//   --no-extra    自作アプリなどの説明の材料（AppExtra）と「いつも開くファイル」を使わない（前の作りと比べる）
//   --show-desc   説明の材料が付いたアプリの説明文を並べる
//   --apps-own <path>  自作アプリの問題（既定 ~/Library/Application Support/Raiden/evals/apps-own.json）
//   --open-bonus <x> / --sweep-open  いつも開くアプリの加点（Engine.openBonus）を変える / 振って比べる
//   --knn-w <x> / --knn-min <x> / --knn-pow <x> / --sweep-knn  アプリの k近傍法（例の重み・最低の近さ・近さの何乗）
//
// 保存済みの例（raiden.sqlite）は読まない。例はこのファイルの EX だけ。
import CoreML
import Foundation
import RaidenCore

let Q: [(String, [String])] = [
    ("PDFを見るやつ", ["プレビュー", "Yomu"]), ("あのファイルを見るやつ", ["プレビュー", "クイックルック"]),
    ("ワードの書類を開くやつ", ["Word", "Pages"]), ("表計算", ["Excel", "Numbers"]),
    ("プレゼン作るやつ", ["Keynote", "PowerPoint"]), ("曲を聴く", ["ミュージック"]),
    ("世界地図見るやつ", ["マップ"]), ("録音するやつ", ["ボイスメモ"]), ("写真を見る", ["写真", "プレビュー"]),
    ("動画を再生", ["QuickTime Player", "TV"]), ("ネット見るやつ", ["Safari", "Google Chrome"]),
    ("黒い画面でコマンド打つやつ", ["ターミナル", "iTerm", "Ghostty"]), ("予定を確認", ["カレンダー"]),
    ("やることリスト", ["リマインダー"]), ("電卓", ["計算機"]), ("メモを書く", ["メモ", "スティッキーズ", "Obsidian"]),
    ("重くなってる原因を調べる", ["アクティビティモニタ"]), ("設定を変える", ["システム設定"]),
    ("スクショ撮る", ["スクリーンショット"]), ("ZIPを解凍", ["アーカイブユーティリティ"]),
    ("経費を記録", ["ふくちょう"]), ("天気", ["天気"]), ("言葉の意味を調べる", ["辞書"]),
    ("顔を見ながら電話", ["FaceTime"]), ("3Dモデルを作る", ["Blender"]),
]

// 過去に選んだ例（言い方 → 選んだアプリ）。答え合わせの 25 個とは別の言い方
let EX: [(String, [String])] = [
    ("プレビュー", ["PDF開いて", "画像をちょっと確認", "書類を表示"]), ("Word", ["docxを開く", "ワード起動"]),
    ("Pages", ["文書を書く"]), ("Excel", ["エクセル", "スプレッドシート開いて"]), ("Numbers", ["表を作る"]),
    ("Keynote", ["スライドを作る", "発表の資料"]), ("PowerPoint", ["パワポ"]), ("ミュージック", ["音楽かけて", "好きな歌を流す"]),
    ("マップ", ["道を調べる", "地図アプリ"]), ("ボイスメモ", ["声を録る", "音声メモ"]), ("写真", ["撮った写真", "アルバム"]),
    ("QuickTime Player", ["mp4を見る", "映像ファイル再生"]), ("Safari", ["ブラウザ", "Webサイトを開く"]),
    ("Google Chrome", ["クローム", "検索する"]), ("ターミナル", ["シェル", "コマンドライン"]), ("iTerm", ["端末"]),
    ("カレンダー", ["スケジュール", "今日の予定"]), ("リマインダー", ["ToDo", "忘れないように登録"]),
    ("計算機", ["計算する", "足し算"]), ("メモ", ["ちょっと書き留める", "メモ帳"]),
    ("アクティビティモニタ", ["CPU使用率", "メモリを食ってるアプリ"]), ("システム設定", ["環境設定", "Wi-Fiの設定"]),
    ("スクリーンショット", ["画面を撮る", "画面キャプチャ"]), ("アーカイブユーティリティ", ["圧縮ファイルを開く", "展開"]),
    ("ふくちょう", ["帳簿", "レシート登録"]), ("天気", ["明日の天気", "雨降る？"]), ("辞書", ["単語を引く", "英単語の意味"]),
    ("FaceTime", ["ビデオ通話", "テレビ電話"]), ("Blender", ["3DCG", "モデリング"]),
]

// 名前の一部（文字一致が効いているかの確認）
let PARTIAL: [(String, [String])] = [
    ("saf", ["Safari"]), ("ターミ", ["ターミナル"]), ("あくてぃ", ["アクティビティモニタ"]), ("xcel", ["Excel"]), ("blen", ["Blender"]),
]

let args = CommandLine.arguments
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

@discardableResult
func run(_ e: Engine, _ qs: [(String, [String])], examples: Bool, _ label: String, verbose: Bool = true) -> (Int, Int, Double) {
    var h1 = 0, h3 = 0
    var ts: [Double] = []
    var miss: [String] = []
    for (q, gold) in qs {
        let t = Date()
        let top = e.search(q, limit: 3, useExamples: examples).map(\.app.jp)
        ts.append(Date().timeIntervalSince(t) * 1000)
        if gold.contains(top[0]) { h1 += 1 } else { miss.append("    外れ \(q) -> \(top)") }
        if top.contains(where: gold.contains) { h3 += 1 }
    }
    if verbose {
        print("\(label): 1位 \(h1)/\(qs.count)  3位以内 \(h3)/\(qs.count)  1回 \(String(format: "%.1f", median(ts)))ms")
        if args.contains("--miss") { miss.forEach { print($0) } }
    }
    return (h1, h3, median(ts))
}

// --compile <in.mlpackage> <out.mlmodelc>（build.sh が使う）
if let i = args.firstIndex(of: "--compile"), i + 2 < args.count {
    let tmp = try MLModel.compileModel(at: URL(fileURLWithPath: args[i + 1]))
    let dst = URL(fileURLWithPath: args[i + 2])
    try? FileManager.default.removeItem(at: dst)
    try FileManager.default.moveItem(at: tmp, to: dst)
    print("compiled \(dst.path)")
    exit(0)
}

let fpStart = physFootprintMB()
// --no-extra: 標準アプリ以外の説明の材料（AppExtra）を使わない（前の作りと比べる用）
let apps = AppCatalog.collect(extras: !args.contains("--no-extra"))
print("アプリ \(apps.count) 個 / 起動時メモリ \(String(format: "%.0f", fpStart))MB")

// --show-desc: 説明の材料が付いたアプリの説明文を並べて終わる
if args.contains("--show-desc") {
    for a in apps where !a.extra.isEmpty || !a.opens.isEmpty { print("[\(a.jp)] \(Describe.text(a))\n") }
    exit(0)
}

// 自作アプリの問題（私的な名前を含むのでリポジトリに入れない）。[{"q": 言い方, "gold": [アプリの日本語名]}]
//   --apps-own <path>（既定 ~/Library/Application Support/Raiden/evals/apps-own.json）。無ければ飛ばす
struct OwnQ: Decodable { let q: String; let gold: [String] }
let ownPath = opt("--apps-own") ?? RaidenPaths.support.appendingPathComponent("evals/apps-own.json").path
let OWN: [(String, [String])] = ((try? JSONDecoder().decode([OwnQ].self, from: Data(contentsOf: URL(fileURLWithPath: ownPath)))) ?? [])
    .map { ($0.q, $0.gold) }

// トークナイザの答え合わせ: --dump-texts <file> で全文を書き出し、Python で正解を作って --check-tokens <file> <ids.json>
func allTexts(_ apps: [AppEntry]) -> [String] {
    apps.map { Describe.text($0, useDict: true) } + apps.map { Describe.text($0, useDict: false) }
        + Q.map(\.0) + EX.flatMap(\.1) + PARTIAL.map(\.0)
}
if let p = opt("--dump-texts") {
    try allTexts(apps).joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8)
    exit(0)
}
if let i = args.firstIndex(of: "--check-tokens"), i + 2 < args.count {
    let tok = try UnigramTokenizer(url: URL(fileURLWithPath: (opt("--model-dir") ?? "/Volumes/SSD/raiden-models") + "/vocab.bin"))
    let texts = try String(contentsOfFile: args[i + 1], encoding: .utf8).components(separatedBy: "\n")
    let ref = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[i + 2]))) as! [[Int]]
    var ok = 0
    for (t, r) in zip(texts, ref) {
        let mine = tok.encode(t).map(Int.init)
        if mine == r { ok += 1 } else if ok < 1000 { print("違う: \(t)\n  swift \(mine)\n  hf    \(r)") }
    }
    print("トークン一致 \(ok)/\(ref.count)")
    exit(0)
}

let embedder: Embedder
var bge: BGEEmbedder?
let t0 = Date()
if args.contains("--nl") {
    embedder = try NLEmbedder()
} else {
    let dir = URL(fileURLWithPath: opt("--model-dir") ?? "/Volumes/SSD/raiden-models")
    let units: MLComputeUnits = ["cpu": .cpuOnly, "gpu": .cpuAndGPU, "all": .all][opt("--units") ?? ""] ?? .cpuAndNeuralEngine
    let b = try BGEEmbedder(modelDir: dir, body: opt("--body") ?? "body.mlmodelc", computeUnits: units)
    try b.load()
    embedder = b
    bge = b
}
print("モデル \(embedder.identifier)  読み込み \(String(format: "%.2f", Date().timeIntervalSince(t0)))s  読み込み後メモリ \(String(format: "%.0f", physFootprintMB()))MB")

// --watch-test --store <path>: FSEvents で変化が検索にすぐ出るかを確かめる（WatchTest.swift）
if args.contains("--watch-test") {
    try runWatchTest(embedder: embedder)
    exit(0)
}

// PyTorch の答えとの突き合わせ（convert.py の reference.json）
if let b = bge, let d = try? Data(contentsOf: b.modelDir.appendingPathComponent("reference.json")),
   let ref = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let texts = ref["texts"] as? [String] {
    let vs = texts.map { b.embed($0) }
    let ids = texts.map { b.tokenize($0) }
    let refIds = ref["ids"] as? [[Int]] ?? []
    let idsOK = zip(ids, refIds).allSatisfy { a, r in a == Array(r.prefix(a.count)) }
    print(String(format: "PyTorch との比較: cos(0,1) %.4f（PyTorch %.4f） cos(0,2) %.4f（PyTorch %.4f） トークン一致 %@",
                 Vec.dot(vs[0], vs[1]), ref["cos01"] as? Double ?? 0, Vec.dot(vs[0], vs[2]), ref["cos02"] as? Double ?? 0,
                 idsOK ? "はい" : "いいえ"))
}

// --store <path>: アプリと同じ SQLite の道筋（nodes/edges）を試す。2 回目の起動はベクトルを作り直さない
if let sp = opt("--store") {
    for round in 1...2 {
        let t = Date()
        let st = try Store(url: URL(fileURLWithPath: sp))
        let e = Engine(embedder: embedder, store: st)
        e.setApps(apps)
        e.loadExamples()
        print(String(format: "store %d 回目: アプリ %d 例 %d  %.2fs", round, st.count(kind: "app"), e.examples.count, Date().timeIntervalSince(t)))
        if round == 1, let calc = apps.first(where: { $0.bundleID == "com.apple.calculator" }) {
            print("  学習前「数字を足したい」->", e.search("数字を足したい", limit: 3).map(\.app.jp))
            e.learn(query: "数字を足したい", app: calc)
            e.learn(query: "数字を足したい", app: calc)
        } else {
            print("  学習後「数字を足したい」->", e.search("数字を足したい", limit: 3).map(\.app.jp),
                  " 似た言い方「数を足す」->", e.search("数を足す", limit: 3).map(\.app.jp))
        }
    }
    exit(0)
}

let tA = Date()
let plain = Engine(embedder: embedder, useDict: false)
plain.setApps(apps)
let rich = Engine(embedder: embedder, useDict: true)
rich.setApps(apps)
var firstKey: [String: String] = [:]
for a in apps where firstKey[a.jp] == nil { firstKey[a.jp] = a.key }
rich.addExamples(EX.flatMap { name, qs in qs.compactMap { q in firstKey[name].map { (q, $0) } } })
print("説明文と例のベクトル化 \(String(format: "%.1f", Date().timeIntervalSince(tA)))s")

// --knn-w / --knn-min / --knn-pow: アプリの k近傍法の重み・数える最低の近さ・近さの何乗を変える（既定は Mix.appDefault）
if let x = opt("--knn-w").flatMap(Float.init) { rich.appMix.wK = x }
if let x = opt("--knn-min").flatMap(Float.init) { rich.appMix.knnMinSim = x }
if let x = opt("--knn-pow").flatMap(Float.init) { rich.appMix.knnSimPow = x }

if args.contains("--files") {
    try runFileEval(embedder: embedder, appQs: Q, appEngine: rich)
    exit(0)
}

if args.contains("--sweep") {
    for w in [0.5, 0.75, 1.0, 1.5, 2.0] as [Float] {
        for ms in [0.0, 0.4, 0.5, 0.6] as [Float] {
            rich.appMix.wK = w; rich.appMix.knnMinSim = ms
            let (h1, h3, _) = run(rich, Q, examples: true, "", verbose: false)
            print("w=\(w) min_sim=\(ms): 1位 \(h1) 3位以内 \(h3)")
        }
    }
    exit(0)
}

// いつも開くアプリの加点。--no-extra のときは前の作りに合わせて 0
let noExtra = args.contains("--no-extra")
for e in [plain, rich] { e.openBonus = noExtra ? 0 : (opt("--open-bonus").flatMap(Float.init) ?? e.openBonus) }
if args.contains("--sweep-open") {
    for b in [0.0, 0.05, 0.1, 0.15, 0.2, 0.3] as [Float] {
        plain.openBonus = b; rich.openBonus = b
        let r = [run(rich, Q, examples: false, "", verbose: false), run(rich, Q, examples: true, "", verbose: false),
                 run(rich, PARTIAL, examples: true, "", verbose: false),
                 run(rich, OWN, examples: false, "", verbose: false), run(rich, OWN, examples: true, "", verbose: false)]
        print("加点 \(b): " + zip(["25問例なし", "25問例あり", "名前の一部", "自作例なし", "自作例あり"], r)
            .map { "\($0) \($1.0)/\($1.1)" }.joined(separator: "  "))
    }
    exit(0)
}
// --sweep-knn: アプリの k近傍法（例の重み・数える最低の近さ・近さの何乗で票にするか）を振る。
//   答えのある問題を「見つからない」と弾いた数も出す（NoMatchRule.apps と食い違わないかの確かめ）
if args.contains("--sweep-knn") {
    let base = rich.appMix
    let all = Q + PARTIAL + OWN
    for w in [0.5, 1.0, 1.25, 1.5, 2.0] as [Float] {
        for ms in [0.0, 0.6] as [Float] {
            for p in [1.0, 4.0, 6.0, 8.0] as [Float] {
                rich.appMix = base
                rich.appMix.wK = w; rich.appMix.knnMinSim = ms; rich.appMix.knnSimPow = p
                let a = run(rich, Q, examples: true, "", verbose: false)
                let b = run(rich, PARTIAL, examples: true, "", verbose: false)
                let c = run(rich, OWN, examples: true, "", verbose: false)
                let rej = all.filter { rich.searchJudged($0.0, limit: 3).noMatch }.count
                print("w=\(w) min=\(ms) pow=\(p): 25問 \(a.0)/\(a.1)  名前 \(b.0)/\(b.1)  自作 \(c.0)/\(c.1)  弾いた \(rej)/\(all.count)")
            }
        }
    }
    exit(0)
}
run(plain, Q, examples: false, "例なし・辞書なし")
run(rich, Q, examples: false, "例なし・辞書あり")
run(rich, Q, examples: true, "例あり・辞書あり")
run(rich, PARTIAL, examples: true, "名前の一部")
if !OWN.isEmpty {
    run(rich, OWN, examples: false, "自作アプリ・例なし")
    run(rich, OWN, examples: true, "自作アプリ・例あり")
}
print(String(format: "答え合わせ後メモリ footprint %.0fMB / 実メモリ(resident) %.0fMB", physFootprintMB(), residentMB()))

if args.contains("--reload"), let b = bge {
    b.unload()
    print(String(format: "解放後メモリ footprint %.0fMB / resident %.0fMB", physFootprintMB(), residentMB()))
    let t = Date()
    _ = rich.search("PDFを見るやつ")
    print(String(format: "再読み込み＋1回目の検索 %.2fs  メモリ %.0fMB", Date().timeIntervalSince(t), physFootprintMB()))
}
