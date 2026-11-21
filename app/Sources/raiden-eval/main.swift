// 答え合わせ。アプリと同じ Engine.search で 25 個の曖昧な言い方を並べ、1位・3位以内の数を出す（埋め込みモデルは使わない）。
//
//   raiden-eval [--miss]
//   --no-extra    自作アプリなどの説明の材料（AppExtra）と「いつも開くファイル」を使わない（前の作りと比べる）
//   --show-desc   辞書の言葉（Describe.dictText）が付いたアプリを並べる
//   --apps-own <path>  自作アプリの問題（既定 ~/Library/Application Support/Raiden/evals/apps-own.json）
//   --apps-3p <path>   他社アプリの問題（既定 ~/Library/Application Support/Raiden/evals/apps-3p.json）
//   RAIDEN_NO_SPOTLIGHT=1  アプリの一覧を Spotlight で広げない（前の作りと比べる）
//   --open-bonus <x>  いつも開くアプリの加点（Engine.openBonus）を変える
//   --test-filters / --filters  入力欄の絞り込みコマンド（FilterEval.swift）
//   --test-spotlight / --bench-spotlight / --boot-bench  Spotlight への置き換えと問い合わせの時間、起動（SpotlightTest.swift）
//   --files  ファイルの答え合わせ（FileEval.swift）
//
// 保存済みの記録（raiden.sqlite）は読まない。「例あり」の記録はこのファイルの EX だけ。
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
    var h1 = 0, h3 = 0, rej = 0
    var ts: [Double] = []
    var miss: [String] = []
    for (q, gold) in qs {
        let t = Date()
        let j = e.searchJudged(q, limit: 3, useExamples: examples)
        let top = j.results.map(\.app.jp)
        ts.append(Date().timeIntervalSince(t) * 1000)
        if j.noMatch { rej += 1 }
        if let f = top.first, gold.contains(f) { h1 += 1 } else { miss.append("    外れ \(q) -> \(top)\(j.noMatch ? "（見つからない）" : "")") }
        if top.contains(where: gold.contains) { h3 += 1 }
    }
    if verbose {
        print("\(label): 1位 \(h1)/\(qs.count)  3位以内 \(h3)/\(qs.count)  見つからない \(rej)  1回 \(String(format: "%.2f", median(ts)))ms")
        if args.contains("--miss") { miss.forEach { print($0) } }
    }
    return (h1, h3, median(ts))
}

// モデルの要らない確かめ
if args.contains("--test-filters") { runFilterTests() }
if args.contains("--test-spotlight") { runSpotlightTests() }
if args.contains("--bench-spotlight") { try runSpotlightBench(); exit(0) }
if args.contains("--boot-bench") { try runBootBench(); exit(0) }
if args.contains("--files") { try runFileEval(); exit(0) }
// --settings-test --store <path>: 設定の読み書き・除外・DB の片付け・記録・動作の記録（SettingsTest.swift）
if args.contains("--settings-test") { try runSettingsTest(); exit(0) }
// --recent: 何も打っていないときに出す最近の作業のまとまり（読むだけ）
if args.contains("--recent") {
    let t0 = Date()
    let es = SpotlightSearch().recent(limit: 40)
    for ss in Recall.sessions(es) { print(ss.title); ss.items.forEach { print("   " + $0.name) } }
    print(String(format: "%.0fms", Date().timeIntervalSince(t0) * 1000))
    exit(0)
}
// --recall <入力>: Spotlight に実際に問い合わせて、件数と絞り込みの問いを見る（読むだけ）
if let q = opt("--recall") {
    let sp = SpotlightSearch()
    let f = QueryFilters.parse(q)
    let r = sp.search(q, filters: f.hasSyntax ? f : nil, limit: 9)
    print("\(q): \(r.total) 件  \(String(format: "%.0f", r.ms))ms（問い \(String(format: "%.0f", r.splitMs))ms）")
    if let s = r.split { print("  \(s.title): " + s.options.map { "\($0.label) \($0.count)（\($0.command)）" }.joined(separator: " / ")) } else { print("  問いなし") }
    exit(0)
}

let fpStart = physFootprintMB()
let tCollect = Date()
let apps = AppCatalog.collect(extras: !args.contains("--no-extra"))
print("アプリ \(apps.count) 個（一覧づくり \(String(format: "%.2f", Date().timeIntervalSince(tCollect)))s） / 起動時メモリ \(String(format: "%.0f", fpStart))MB")
if args.contains("--list-apps") {
    for a in apps { print("\(a.jp)\t\(a.bundleID)\t\(a.path)") }
    exit(0)
}
if args.contains("--show-desc") {
    for a in apps { print("[\(a.jp)] \(Describe.dictText(a))\n") }
    exit(0)
}

// 自作アプリの問題（私的な名前を含むのでリポジトリに入れない）。[{"q": 言い方, "gold": [アプリの日本語名]}]
struct OwnQ: Decodable { let q: String; let gold: [String] }
let ownPath = opt("--apps-own") ?? RaidenPaths.support.appendingPathComponent("evals/apps-own.json").path
func loadQs(_ path: String) -> [(String, [String])] {
    ((try? JSONDecoder().decode([OwnQ].self, from: Data(contentsOf: URL(fileURLWithPath: path)))) ?? []).map { ($0.q, $0.gold) }
}
let OWN = loadQs(ownPath)
let THIRD = loadQs(opt("--apps-3p") ?? RaidenPaths.support.appendingPathComponent("evals/apps-3p.json").path)

// --log-eval --store <path>: 検索の記録（search_log）で答え合わせ（SettingsTest.swift）
if args.contains("--log-eval") { try runLogEval(apps: apps); exit(0) }

// --store <path>: アプリと同じ SQLite の道筋（nodes/edges）を試す
if let sp = opt("--store") {
    guard sp != Store.defaultURL.path else { print("本物の raiden.sqlite は使えません"); exit(1) }
    for round in 1...2 {
        let t = Date()
        let st = try Store(url: URL(fileURLWithPath: sp))
        let e = Engine(store: st)
        e.setApps(apps)
        e.loadExamples()
        print(String(format: "store %d 回目: 記録 %d  %.2fs", round, e.examples.count, Date().timeIntervalSince(t)))
        if round == 1, let calc = apps.first(where: { $0.bundleID == "com.apple.calculator" }) {
            print("  学習前「数字を足したい」->", e.search("数字を足したい", limit: 3).map(\.app.jp))
            e.learn(query: "数字を足したい", app: calc)
            e.learn(query: "数字を足したい", app: calc)
        } else {
            print("  学習後「数字を足したい」->", e.search("数字を足したい", limit: 3).map(\.app.jp),
                  " 似た言い方「数字を足す」->", e.search("数字を足す", limit: 3).map(\.app.jp))
        }
    }
    exit(0)
}

let tA = Date()
let plain = Engine(useDict: false)
plain.setApps(apps)
let rich = Engine(useDict: true)
rich.setApps(apps)
var firstKey: [String: String] = [:]
for a in apps where firstKey[a.jp] == nil { firstKey[a.jp] = a.key }
rich.addExamples(EX.flatMap { name, qs in qs.compactMap { q in firstKey[name].map { (q, $0) } } })
print("辞書と記録の準備 \(String(format: "%.1f", Date().timeIntervalSince(tA) * 1000))ms")

if args.contains("--filters") { try runFilterEval(appEngine: rich); exit(0) }

// いつも開くアプリの加点。--no-extra のときは前の作りに合わせて 0
let noExtra = args.contains("--no-extra")
for e in [plain, rich] { e.openBonus = noExtra ? 0 : (opt("--open-bonus").flatMap(Float.init) ?? e.openBonus) }
run(plain, Q, examples: false, "例なし・辞書なし")
run(rich, Q, examples: false, "例なし・辞書あり")
run(rich, Q, examples: true, "例あり・辞書あり")
run(rich, PARTIAL, examples: true, "名前の一部")
if !OWN.isEmpty {
    run(rich, OWN, examples: false, "自作アプリ・例なし")
    run(rich, OWN, examples: true, "自作アプリ・例あり")
}
if !THIRD.isEmpty {
    run(rich, THIRD, examples: false, "他社アプリ・例なし")
    run(rich, THIRD, examples: true, "他社アプリ・例あり")
}
print(String(format: "答え合わせ後メモリ footprint %.0fMB / 実メモリ(resident) %.0fMB", physFootprintMB(), residentMB()))
