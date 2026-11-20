import Foundation
import RaidenCore

/// 広い範囲の一覧で Ranker.rank の段ごとの時間を測る（raiden-eval --bench-rank --roots ~/Project [--runs 5]）。
/// 一覧は FileCatalog.collect（ユーザーのファイルは名前と日付を読むだけ）。2 値のベクトルは乱数（全件あり）、
/// 例は乱数のつながりで 60 個。入力のベクトルは本物の embedder で作る。データベースには触らない。
/// 名前の索引あり・なしで、名前の一致の点数（全件）と上位 20 件が同じかも比べる
func runBenchRank(embedder: Embedder) {
    let roots = (opt("--roots") ?? "~/Project").split(separator: ",").map { String($0) }
    let scope = ScanScope(roots: roots)
    let runs = opt("--runs").flatMap(Int.init) ?? 5
    var t = Date()
    let entries = loadOrCollectEntries(scope: scope)
    print(String(format: "一覧 %d 件 %.1fs", entries.count, Date().timeIntervalSince(t)))
    var rng = SystemRandomNumberGenerator()
    var codes = [UInt8](repeating: 0, count: entries.count * BinVec.bytes)
    for i in codes.indices { codes[i] = UInt8.random(in: 0...255, using: &rng) }
    let fp0 = physFootprintMB()
    t = Date()
    var c = Corpus()
    c.setItems(names: entries.map { [$0.stem] }, codes: codes, present: Array(repeating: true, count: entries.count), meta: entries.map {
        Corpus.Meta(families: Set($0.families), times: [$0.lastUsed, $0.mtime, $0.added].filter { $0 > 0 },
                    added: $0.added, downloaded: $0.downloaded)
    })
    let tSet = Date().timeIntervalSince(t)
    print(String(format: "Corpus.setItems %.2fs（名前の正規化・読み・索引を含む）footprint +%.0fMB", tSet, physFootprintMB() - fp0))
    printIndexStats(c)
    c.addEdges(contains: FileCatalog.containsEdges(entries), coUsed: FileCatalog.coUsedEdges(entries), coTime: FileCatalog.coTimeEdges(entries))
    for j in 0..<60 {
        let v = embedder.embed("例 \(j)")
        c.addExample(text: "例 \(j)", vec: v, links: [(Int.random(in: 0..<entries.count), 1)])
    }
    let qs = opt("--queries")?.split(separator: "|").map(String.init) ?? [
        "r", "設", "re", "pd", "画像", "readme", "unity", "invoice", "package", "設計書", "請求書のPDF", "先週のスクショ",
        "raedme", "untiy", "seikyuusyo", "mitumori", "あのとき作った音声入力のやつ", "Swift のランチャーの説明",
    ]
    let mix = Mix.fileDefault
    var m0 = mix; m0.k = false
    let now = Date()
    let doCompare = !args.contains("--no-compare")
    var stageTotal: [String: Double] = [:]
    var rows: [String] = []
    var mismatch = 0
    for q in qs {
        let vec = embedder.embed(q)
        let it = QueryIntent.parse(q, now: now)
        // 1 回の検索と同じ並べ方: 例ありで rank → 例なしで rank → 見つからないの手がかり（もう一度全件の近さ）
        func once() -> [(Int, Float)] {
            let r = Ranker.rank(c, query: q, vec: vec, mix: mix, intent: it, limit: 10)
            let r0 = Ranker.rank(c, query: q, vec: vec, mix: m0, intent: it, limit: 10)
            _ = NoMatch.signals(c, query: q, vec: vec, mix: mix, ranked: r, rankedNoEx: r0, intent: it, relation: false)
            return r
        }
        _ = once()
        var ts: [Double] = [], rankTs: [Double] = []
        var prof: [String: Double] = [:]
        for _ in 0..<runs {
            Ranker.profile = [:]
            let t1 = DispatchTime.now().uptimeNanoseconds
            _ = Ranker.rank(c, query: q, vec: vec, mix: mix, intent: it, limit: 10)
            rankTs.append(Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6)
            for (k, v) in Ranker.profile! { prof[k, default: 0] += v / Double(runs) }
            Ranker.profile = nil
            let t2 = DispatchTime.now().uptimeNanoseconds
            _ = once()
            ts.append(Double(DispatchTime.now().uptimeNanoseconds - t2) / 1e6)
        }
        for (k, v) in prof { stageTotal[k, default: 0] += v / Double(qs.count) }
        let stages = prof.sorted { $0.value > $1.value }.prefix(3).map { String(format: "%@ %.1f", $0.key, $0.value) }.joined(separator: ", ")
        rows.append(String(format: "  %-28@ rank %6.1fms  検索1回（rank×2＋見つからない）%6.1fms  [%@]", q as NSString, median(rankTs), median(ts), stages))
        if doCompare {
            let on = Ranker.rank(c, query: q, vec: vec, mix: mix, intent: it, limit: 20)
            let bOn = Ranker.nameBonus(c, query: q, mix: mix)
            Ranker.useNameIndex = false
            let off = Ranker.rank(c, query: q, vec: vec, mix: mix, intent: it, limit: 20)
            let bOff = Ranker.nameBonus(c, query: q, mix: mix)
            Ranker.useNameIndex = true
            let same = on.map(\.0) == off.map(\.0) && zip(on, off).allSatisfy { $0.1 == $1.1 }
            let diff = zip(bOn, bOff).filter { $0 != $1 }.count
            let hits = bOff.filter { $0 > 0 }.count
            if !same || diff > 0 { mismatch += 1 }
            rows.append("      索引あり・なし: 上位 20 件 \(same ? "同じ" : "違う")  名前の点数が違う件数 \(diff)（当たり \(hits) 件）")
        }
    }
    rows.forEach { print($0) }
    print("段ごとの平均（rank 1 回、ms）: " + stageTotal.sorted { $0.value > $1.value }.map { String(format: "%@ %.1f", $0.key, $0.value) }.joined(separator: " / "))
    if doCompare { print(mismatch == 0 ? "索引あり・なしは全部同じ" : "索引あり・なしで違う入力 \(mismatch) 個") }
    if args.contains("--fuzz") { checkMyers(); fuzzNameIndex(c, entries: entries, embedder: embedder) }
}

/// 名前の一部・打ち間違いを乱数で作り、索引あり・なしの名前の点数を全件で比べる
func fuzzNameIndex(_ c: Corpus, entries: [FileEntry], embedder: Embedder) {
    let mix = Mix.fileDefault
    let n = opt("--fuzz").flatMap(Int.init) ?? 300
    var bad = 0
    var tOn = 0.0, tOff = 0.0
    for k in 0..<n {
        let e = entries[Int.random(in: 0..<entries.count)]
        var cs = Array(Lexical.romaji(e.stem).isEmpty || k % 2 == 0 ? e.stem : Lexical.romaji(e.stem))
        guard !cs.isEmpty else { continue }
        let len = min(cs.count, Int.random(in: 1...8))
        let st = Int.random(in: 0...(cs.count - len))
        cs = Array(cs[st..<(st + len)])
        switch k % 4 {
        case 1 where cs.count > 2: cs.remove(at: Int.random(in: 0..<cs.count))
        case 2 where cs.count > 1: cs.swapAt(0, 1)
        case 3: cs.insert(Character(Unicode.Scalar(UInt8.random(in: 97...122))), at: Int.random(in: 0...cs.count))
        default: break
        }
        let q = String(cs)
        var t1 = Date()
        let a = Ranker.nameBonus(c, query: q, mix: mix)
        tOn += Date().timeIntervalSince(t1)
        Ranker.useNameIndex = false
        t1 = Date()
        let b = Ranker.nameBonus(c, query: q, mix: mix)
        tOff += Date().timeIntervalSince(t1)
        Ranker.useNameIndex = true
        if a != b { bad += 1; if bad <= 10 { print("  違う: \(q) \(zip(a, b).filter { $0 != $1 }.count) 件") } }
    }
    print(String(format: "乱数の入力 %d 個: 名前の点数が違う入力 %d 個（名前の一致の平均 索引あり %.1fms・なし %.1fms）", n, bad, tOn * 1000 / Double(n), tOff * 1000 / Double(n)))
}

func printIndexStats(_ c: Corpus) {
    print("名前の索引: " + c.nameIndexSummary)
}

/// ビット並列の距離が前の表の作りと同じ値か（乱数の文字列で）
func checkMyers() {
    var bad = 0
    let alpha = Array("aiueoknstmrあ")
    for _ in 0..<200_000 {
        let q = String((0..<Int.random(in: 1...12)).map { _ in alpha.randomElement()! })
        let t = String((0..<Int.random(in: 0...30)).map { _ in alpha.randomElement()! })
        if Lexical.approxSubstringDistanceDP(Array(q.utf8), Array(t.utf8)) != Lexical.approxSubstringDistance(q, in: t) { bad += 1 }
    }
    print("距離の確かめ: 乱数 200000 組で前の作りと違う \(bad) 組")
}

/// --entries <path>: あればそれを読み、無ければ一覧を作って書き出す（~/Project 16.9 万件の一覧は 3 分以上かかるので 1 回だけ）
func loadOrCollectEntries(scope: ScanScope) -> [FileEntry] {
    guard let p = opt("--entries") else { return FileCatalog.collect(scope: scope) }
    let url = URL(fileURLWithPath: p)
    if let d = try? Data(contentsOf: url), let es = try? JSONDecoder().decode([FileEntry].self, from: d) { return es }
    let es = FileCatalog.collect(scope: scope)
    try? JSONEncoder().encode(es).write(to: url)
    print("一覧を書き出し \(es.count) 件 → \(p)")
    return es
}

/// 文字列から決まる乱数のベクトル（モデルを読まずに並べ方の時間を測る用）
final class HashEmbedder: Embedder {
    var identifier: String { "hash" }
    var dimension: Int { 1024 }
    func embed(_ text: String) -> [Float] {
        var h: UInt64 = 1469598103934665603
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        var x = h | 1
        let v = (0..<1024).map { _ -> Float in
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            return Float(Int64(bitPattern: x) % 1000) / 1000
        }
        return Vec.normalized(v)
    }
}
