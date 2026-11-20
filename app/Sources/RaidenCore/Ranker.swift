import Accelerate
import Foundation

/// 並べ方の組み合わせ。
///   V: 説明文との近さ（ベクトル）
///   K: k近傍法（入力に近い過去の例 → chose の線 → 点）
///   G: グラフ（入口の点から contains / co_used / chose の線をたどって点数を広げる）
///      V か K があるときは、その点数の上位 N 件を入口にする。G だけのときは文字の重なり（ベクトルを使わない）で入口を選ぶ。
/// 名前の文字一致・時間と種類の絞り込みは、どの組み合わせにも共通で足す。
public struct Mix: Sendable, CustomStringConvertible {
    public enum Fusion: String, Sendable { case sum, rrf }
    public var v = true, k = true, g = false
    public var fusion: Fusion = .sum
    public var wV: Float = 1, wK: Float = 1, wG: Float = 1
    public var knnK = 5
    public var knnMinSim: Float = 0
    public var knnSimPow: Float = 1  // 例の票 = 近さ^これ（大きいほど近い例だけが強く効く。1 なら近さそのまま）
    public var seeds = 10            // グラフの入口の数 N
    public var alpha: Float = 0.5    // 1 回たどるごとに掛ける割合
    public var hops = 1
    public var contains = true, coUsed = true, coTime = false, up = true   // up: 中の物 → フォルダにも広げる
    public var coWeight: Float = 1
    public var rrfK: Float = 60
    public var prefixBonus: Float = 0.6, substrBonus: Float = 0.35, fuzzyBonus: Float = 0.3
    public var intents = false       // 時間・種類の言葉で絞る
    public var typeBonus: Float = 0.15
    public var timeBonus: Float = 0.3
    public var timeFilter = true     // 時間の言葉があれば範囲外を下げる（-1）
    public var folderBonus: Float = 0.15  // 「〜のとこ」「フォルダ」などでフォルダを上げる
    // フォルダの扱い（入力の一番後ろの種類の言葉がフォルダの言葉のとき = QueryIntent.wantsFolder）
    public var folderHeadOnly = true       // フォルダ加点・下記の加点は wantsFolder のときだけ（「〜フォルダの画像」では上げない）
    public var emptyFolderBonus = false    // false: 下にファイルが 1 個も無いフォルダには加点しない
    public var folderTypeBonus: Float = 0.2  // 「PDFが入ってるとこ」: 下のファイルのうち種類が合う割合 × これ（スクショは画像でも当たり）
    public var folderCrowd: Float = 0.01   // 子が crowdMin 件以上、近さの上位 crowdTop にいれば、1 件ごとにこれを親に足す
    public var crowdTop = 20, crowdMin = 2
    public var folderTimeByChildren = true // 時間の言葉は、フォルダなら中の物の日付でも当たりにする
    // つながりの言い方（QueryIntent.anchor/target）があるとき: anchor のベクトルで入口を選び、線をたどった点数 ＋ target との近さで並べる
    public var relation = false
    public var relAlpha: Float = 1.0
    public var relWT: Float = 1.0      // target との近さの重み
    public var relEdges: (contains: Bool, coUsed: Bool, coTime: Bool)? = nil  // nil なら G と同じ線
    public var relByKind = false       // 「の中の」は contains、「同じ日」は co_used/co_time と、言い方で線を選ぶ
    public init() {}

    public var label: String {
        var s = [v ? "V" : nil, k ? "K" : nil, g ? "G" : nil].compactMap { $0 }.joined(separator: "+")
        if s.isEmpty { s = "名前だけ" }
        return s
    }
    public var description: String {
        var d = "\(label) \(fusion.rawValue)"
        if relation { d += " 分割(α=\(relAlpha) wT=\(relWT)\(relByKind ? " 線を言い方で" : ""))" }
        if g { d += " N=\(seeds) α=\(alpha) 回=\(hops)\(contains ? " c" : "")\(up && contains ? "↑" : "")\(coUsed ? " co" : "")\(coTime ? " ct" : "")" }
        if fusion == .sum && (wV != 1 || wK != 1 || wG != 1) { d += " w=\(wV)/\(wK)/\(wG)" }
        if intents { d += " 絞込" }
        return d
    }
}

/// 並べる対象（アプリ・ファイル）と、例・線をまとめたもの。
public struct Corpus {
    public struct Meta: Sendable {
        public var families: Set<String>
        public var times: [Int]       // 使った・変更・追加の日時（どれかが範囲に入れば当たり）
        public var added: Int
        public var downloaded: Bool
        public init(families: Set<String>, times: [Int], added: Int, downloaded: Bool) {
            self.families = families; self.times = times; self.added = added; self.downloaded = downloaded
        }
    }
    public struct Edge: Sendable { public var to: Int32; public var w: Float; public var kind: UInt8 } // 0 中へ 1 外へ 2 co_used 3 co_time

    public private(set) var vecs: [[Float]] = []
    private(set) var flat: [Float] = []   // vecs を 1 本に並べたもの（内積をまとめて Accelerate で計算する）
    public var dim: Int { vecs.first?.count ?? 0 }

    /// 2 値のベクトル（ファイル・フォルダ）。n 件 × 128 バイトを 1 本に並べたもの。これがあるときは vecs は空（BinVec）
    public private(set) var codes: [UInt8] = []
    public private(set) var isBinary = false
    /// 2 値のとき、ベクトルがある点か（まだ作っていない点は false）
    public private(set) var present: [Bool] = []
    private var n = 0

    /// 全部の点との近さ。2 値なら非対称の内積（BinVec、cos の目盛りに合わせてある）、そうでなければ内積（vDSP_mmul）
    public func dots(_ v: [Float]) -> [Float] {
        if isBinary {
            var s = BinVec.scores(codes: codes, n: n, query: v)
            for i in 0..<n where !present[i] { s[i] = 0 }   // まだベクトルの無い点は 0（名前の一致と絞り込みだけで出る）
            return s
        }
        let n = vecs.count, d = dim
        var out = [Float](repeating: 0, count: n)
        guard n > 0, d > 0, v.count == d else { return vecs.map { Vec.dot($0, v) } }
        flat.withUnsafeBufferPointer { a in v.withUnsafeBufferPointer { x in out.withUnsafeMutableBufferPointer { y in
            vDSP_mmul(a.baseAddress!, 1, x.baseAddress!, 1, y.baseAddress!, 1, vDSP_Length(n), 1, vDSP_Length(d))
        } } }
        return out
    }
    public private(set) var names: [[String]] = []     // 正規化した名前（文字一致用）
    public private(set) var romaji: [String] = []      // 名前の読みのローマ字（打ち間違い・ローマ字入力用）
    var grams: [Set<String>] = []
    public var meta: [Meta?] = []
    public var adj: [[Edge]] = []
    /// 下（何段でも）にあるファイルの数。フォルダでない点は 0
    public private(set) var filesBelow: [Int] = []
    /// フォルダの下（何段でも）のファイルの種類ごとの数
    public private(set) var familiesBelow: [Int: [String: Int]] = [:]
    // 例（入力文 → 選んだ点）
    public private(set) var exText: [String] = []
    public private(set) var exVecs: [[Float]] = []
    public private(set) var exLinks: [[(Int, Float)]] = []
    var exGrams: [Set<String>] = []

    public init() {}
    public var count: Int { n }

    // 名前の索引（NameIndex）。setItems で作り直す。作った後に名前が変わった点は nameDirty に入れ、索引を使わず前の比べ方で見る
    private(set) var nameIndex: NameIndex?
    private(set) var nameDirty = Set<Int>()
    public var nameIndexSummary: String { nameIndex.map { $0.summary + " 変わった点 \(nameDirty.count)" } ?? "なし" }
    /// 名前の索引の大きさ（バイト）と作った秒数
    public var nameIndexStats: (bytes: Int, seconds: Double) { (nameIndex?.bytes ?? 0, nameIndex?.buildSeconds ?? 0) }

    /// 名前の索引を今の names / romaji で作り直す（一覧を差分で直した後、変わった点がたまったときに呼ぶ）
    public mutating func rebuildNameIndex() {
        nameIndex = NameIndex(names: names, romaji: romaji)
        nameDirty = []
    }

    /// 点 i の名前・読みを索引を作った後に変えた（または消した）印。後ろに足した点は印が無くても前の比べ方で見る
    public mutating func markNameChanged(_ i: Int) {
        if let ix = nameIndex, i < ix.count { nameDirty.insert(i) }
    }

    public mutating func setItems(names raw: [[String]], vecs: [[Float]], meta: [Meta?]? = nil) {
        self.vecs = vecs
        isBinary = false; codes = []
        let d = vecs.first?.count ?? 0
        flat = vecs.allSatisfy { $0.count == d } ? vecs.flatMap { $0 } : []
        setNames(raw, meta: meta)
    }

    /// 2 値のベクトルで入れる（codes は names.count × 128 バイト）
    public mutating func setItems(names raw: [[String]], codes: [UInt8], present: [Bool], meta: [Meta?]? = nil) {
        vecs = []; flat = []
        isBinary = true
        self.codes = codes
        self.present = present
        setNames(raw, meta: meta)
    }

    private mutating func setNames(_ raw: [[String]], meta: [Meta?]?) {
        n = raw.count
        names = raw.map(Self.normNames)
        romaji = raw.map(Self.romajiOf)
        grams = names.map(Self.gramsOf)
        self.meta = meta ?? Array(repeating: nil, count: n)
        adj = Array(repeating: [], count: n)
        filesBelow = Array(repeating: 0, count: n)
        familiesBelow = [:]
        alive = Array(repeating: true, count: n)
        deadCount = 0
        rebuildNameIndex()
    }

    static func normNames(_ raw: [String]) -> [String] { Array(Set(raw.map(Lexical.normalize).filter { !$0.isEmpty })) }
    static func romajiOf(_ raw: [String]) -> String { Lexical.canonRomaji(Lexical.romaji(raw.first ?? "")) }
    static func gramsOf(_ names: [String]) -> Set<String> { Lexical.bigrams(names.joined(separator: " ")) }

    // MARK: - 差分で直す（ファイル・フォルダ。FSEvents の数件の変化で全部を作り直さない）
    //
    // 添字をずらさないため、消した点は印（alive = false）を付けて検索から外すだけにし、足した点は後ろに足す。
    // 印がたまったら Engine が全部入れ直して詰める（FileIndex の compact*、起動時と 1 日 1 回の見直しでも詰まる）。
    // co_used / co_time の線は全部入れ直すときだけ作り直す（足した点には付かず、重みの割り算もそのまま）。

    /// 生きている点か（false は消した印。並べる・数えるときは外す）
    public private(set) var alive: [Bool] = []
    /// 消した印の数
    public private(set) var deadCount = 0

    /// 絞り込み（allow）に消した印を重ねる。印が無ければ allow のまま
    public func liveAllow(_ allow: [Bool]?) -> [Bool]? {
        guard deadCount > 0 else { return allow }
        guard let allow, allow.count == n else { return alive }
        return zip(allow, alive).map { $0 && $1 }
    }

    /// 2 値のベクトルの点を後ろに 1 つ足す（ベクトル無し・線無し）。足した添字を返す
    public mutating func appendItem(names raw: [String], meta m: Meta?) -> Int {
        precondition(isBinary)
        let nn = Self.normNames(raw)
        names.append(nn); romaji.append(Self.romajiOf(raw)); grams.append(Self.gramsOf(nn))
        meta.append(m); adj.append([]); filesBelow.append(0); alive.append(true)
        codes.append(contentsOf: repeatElement(0, count: BinVec.bytes)); present.append(false)
        n += 1
        return n - 1
    }

    /// 点の名前と時間・種類を差し替える（同じパスの物が変わったとき）
    public mutating func updateItem(_ i: Int, names raw: [String], meta m: Meta?) {
        let nn = Self.normNames(raw)
        names[i] = nn; romaji[i] = Self.romajiOf(raw); grams[i] = Self.gramsOf(nn)
        meta[i] = m
        markNameChanged(i)
    }

    /// ベクトルを外す（説明文が変わってまだ作っていない）
    public mutating func clearCode(_ i: Int) { if isBinary && i < n { present[i] = false } }

    /// 点を消した印にする。つながっている点からの線も外す（下のファイル数は先に addBelow で引いておく）
    public mutating func kill(_ i: Int) {
        guard i < n, alive[i] else { return }
        for e in adj[i] { let t = Int(e.to); if t != i { adj[t].removeAll { $0.to == Int32(i) } } }
        adj[i] = []
        names[i] = []; romaji[i] = ""; grams[i] = []; meta[i] = nil
        markNameChanged(i)
        if isBinary { present[i] = false }
        filesBelow[i] = 0; familiesBelow[i] = nil
        alive[i] = false
        deadCount += 1
    }

    /// contains の線（フォルダ parent → 中の物 child）を 1 本足す
    public mutating func addContains(parent: Int, child: Int) {
        adj[parent].append(Edge(to: Int32(child), w: 1, kind: 0))
        adj[child].append(Edge(to: Int32(parent), w: 1, kind: 1))
    }

    /// ファイル i の上のフォルダ（contains の線を上へ、最大 64 段）の「下のファイル数と種類」に delta を足す。
    /// addEdges の数え方と同じ（フォルダ自身は数えない）
    public mutating func addBelow(_ i: Int, _ delta: Int) {
        guard i < n, let md = meta[i], !md.families.contains("folder") else { return }
        var cur = i
        for _ in 0..<64 {
            guard let up = adj[cur].first(where: { $0.kind == 1 }) else { return }
            let p = Int(up.to)
            guard meta[p]?.families.contains("folder") ?? false else { return }
            filesBelow[p] += delta
            var fam = familiesBelow[p] ?? [:]
            for f in md.families { fam[f, default: 0] += delta; if fam[f] == 0 { fam[f] = nil } }
            familiesBelow[p] = filesBelow[p] > 0 ? fam : nil
            cur = p
        }
    }

    /// 消した点に向いた例の線を外す。線が 1 本も残らない例は例ごと外す（全部入れ直したときと同じになる）
    public mutating func removeLinks(to dead: Set<Int>) {
        guard !dead.isEmpty else { return }
        var keep: [Int] = []
        for j in exLinks.indices {
            exLinks[j].removeAll { dead.contains($0.0) }
            if !exLinks[j].isEmpty { keep.append(j) }
        }
        guard keep.count < exLinks.count else { return }
        exText = keep.map { exText[$0] }; exVecs = keep.map { exVecs[$0] }
        exLinks = keep.map { exLinks[$0] }; exGrams = keep.map { exGrams[$0] }
    }

    /// 1 点の 2 値のベクトルを差し替える（裏でベクトル化が進んだとき）
    public mutating func setCode(_ i: Int, _ c: [UInt8]) {
        guard isBinary, i < n, c.count == BinVec.bytes else { return }
        codes.withUnsafeMutableBufferPointer { p in for j in 0..<BinVec.bytes { p[i * BinVec.bytes + j] = c[j] } }
        present[i] = true
    }

    /// 1 点の 2 値のベクトル（128 バイト）
    public func code(_ i: Int) -> ArraySlice<UInt8> { codes[(i * BinVec.bytes)..<((i + 1) * BinVec.bytes)] }

    public mutating func addEdges(contains: [(Int, Int)], coUsed: [(Int, Int, Float)], coTime: [(Int, Int, Float)] = []) {
        for (a, b, w) in coTime {
            adj[a].append(Edge(to: Int32(b), w: w, kind: 3))
            adj[b].append(Edge(to: Int32(a), w: w, kind: 3))
        }
        for (a, b) in contains {
            adj[a].append(Edge(to: Int32(b), w: 1, kind: 0))
            adj[b].append(Edge(to: Int32(a), w: 1, kind: 1))
        }
        // フォルダの下（何段でも）のファイルの数と種類の内訳
        var kids = [[Int]](repeating: [], count: count)
        for (a, b) in contains { kids[a].append(b) }
        func isFolder(_ i: Int) -> Bool { meta[i]?.families.contains("folder") ?? false }
        func walk(_ i: Int, _ depth: Int, _ n: inout Int, _ fam: inout [String: Int]) {
            guard depth < 64 else { return }
            for k in kids[i] {
                if isFolder(k) { walk(k, depth + 1, &n, &fam) } else { n += 1; for f in meta[k]?.families ?? [] { fam[f, default: 0] += 1 } }
            }
        }
        for i in 0..<count where isFolder(i) && !kids[i].isEmpty {
            var n = 0, fam: [String: Int] = [:]
            walk(i, 0, &n, &fam)
            filesBelow[i] = n
            if n > 0 { familiesBelow[i] = fam }
        }
        // co_used の重みはその点の最大の回数で割って 0〜1 にする
        var mx = [Float](repeating: 0, count: count)
        for (a, b, w) in coUsed { mx[a] = max(mx[a], w); mx[b] = max(mx[b], w) }
        for (a, b, w) in coUsed {
            adj[a].append(Edge(to: Int32(b), w: w / mx[a], kind: 2))
            adj[b].append(Edge(to: Int32(a), w: w / mx[b], kind: 2))
        }
    }

    /// 例を足す。links は（点の添字, 回数）
    public mutating func addExample(text: String, vec: [Float], links: [(Int, Float)]) {
        if let i = exText.firstIndex(of: text) {
            for (t, w) in links {
                if let j = exLinks[i].firstIndex(where: { $0.0 == t }) { exLinks[i][j].1 += w } else { exLinks[i].append((t, w)) }
            }
            return
        }
        exText.append(text); exVecs.append(vec); exLinks.append(links)
        exGrams.append(Lexical.bigrams(Lexical.normalize(text)))
    }

    public mutating func clearExamples() { exText = []; exVecs = []; exLinks = []; exGrams = [] }
}

public enum Ranker {
    /// 段ごとの時間（ms）を足していく（raiden-eval --bench-rank で使う。nil なら測らない）
    nonisolated(unsafe) public static var profile: [String: Double]?
    @inline(__always) static func lap(_ name: String, _ t: inout UInt64) {
        guard profile != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        profile![name, default: 0] += Double(now - t) / 1e6
        t = now
    }

    /// 上位 limit 件の（添字, 点数）を返す
    /// rel: つながりの言い方の anchor / target のベクトル（mix.relation のときだけ使う）
    /// 名前の索引を使うか（false なら全件の名前を 1 件ずつ見る。答え合わせで比べる用）
    nonisolated(unsafe) public static var useNameIndex = true

    /// 名前の文字一致の点数（全件）。先頭・単語の先頭 prefixBonus、途中 substrBonus、
    /// どちらも無ければ読みのローマ字に打ち間違い 1 文字まで fuzzyBonus（0 文字違い ×1、1 文字違い ×0.8）
    public static func nameBonus(_ c: Corpus, query q: String, mix m: Mix) -> [Float] {
        let n = c.count
        let nq = Lexical.normalize(q)
        var bonus = [Float](repeating: 0, count: n)
        let asciiQ = nq.allSatisfy { $0.isASCII }
        let rq = asciiQ ? Lexical.canonRomaji(nq.filter { $0.isLetter || $0.isNumber }) : ""
        guard !nq.isEmpty && !(asciiQ && nq.count < 2) else { return bonus }
        if useNameIndex, let ix = c.nameIndex, ix.count <= n, ix.fill(nq: nq, rq: rq, mix: m, &bonus) {
            // 索引で見ない点（1 文字が 1 コードポイントでない名前・作った後に変わった点・後ろに足した点）は前の比べ方で
            for i in ix.slow { bonus[i] = nameBonus(c, i, nq: nq, rq: rq, mix: m) }
            for i in c.nameDirty where i < n { bonus[i] = nameBonus(c, i, nq: nq, rq: rq, mix: m) }
            for i in ix.count..<n { bonus[i] = nameBonus(c, i, nq: nq, rq: rq, mix: m) }
            return bonus
        }
        for i in 0..<n { bonus[i] = nameBonus(c, i, nq: nq, rq: rq, mix: m) }
        return bonus
    }

    /// 1 件の名前の文字一致（索引を使わない比べ方）
    static func nameBonus(_ c: Corpus, _ i: Int, nq: String, rq: String, mix m: Mix) -> Float {
        var best: Float = 0
        for nn in c.names[i] {
            let words = nn.split(whereSeparator: { " -_.".contains($0) })
            if nn.hasPrefix(nq) || words.contains(where: { $0.hasPrefix(nq) }) { best = max(best, m.prefixBonus) }
            else if nn.contains(nq) { best = max(best, m.substrBonus) }
        }
        if best == 0 && m.fuzzyBonus > 0 && rq.count >= 3 && !c.romaji[i].isEmpty {
            let d = Lexical.approxSubstringDistance(rq, in: c.romaji[i])
            if d == 0 || (d == 1 && rq.count >= 4) { best = m.fuzzyBonus * (d == 0 ? 1 : 0.8) }
        }
        return best
    }

    public static func rank(_ c: Corpus, query q: String, vec v: [Float], mix m: Mix,
                            intent: QueryIntent? = nil, rel: (anchor: [Float], target: [Float])? = nil,
                            limit: Int = 8, allow: [Bool]? = nil) -> [(Int, Float)] {
        if m.relation, let it = intent, it.hasRelation, let rel {
            // 絞り込み（allow）があるときは全部並べてから当てはまる物だけ残す（消した印の点は rankRelation の中で外す）
            guard let allow else { return rankRelation(c, it, rel, m, limit) }
            return Array(rankRelation(c, it, rel, m, c.count).filter { allow[$0.0] }.prefix(limit))
        }
        // 消した印の点（差分で直したときの穴）は絞り込みと同じく候補から外す
        let allow = c.liveAllow(allow)
        let n = c.count
        if n == 0 { return [] }
        var tp = profile != nil ? DispatchTime.now().uptimeNanoseconds : 0
        let nq = Lexical.normalize(q)
        // 名前の文字一致（全方式に共通）
        let bonus = nameBonus(c, query: q, mix: m)
        lap("名前の一致", &tp)
        // V
        var V = [Float](repeating: 0, count: n)
        if m.v { V = c.dots(v) }
        lap("ベクトル", &tp)
        // K
        var K = [Float](repeating: 0, count: n)
        if m.k && !c.exVecs.isEmpty {
            let sims = c.exVecs.map { Vec.dot($0, v) }
            let order = topIndices(sims, m.knnK)
            for (rank, i) in order.enumerated() {
                if sims[i] < m.knnMinSim { break }
                let total = c.exLinks[i].reduce(0) { $0 + $1.1 }
                let sw = m.knnSimPow == 1 ? sims[i] : pow(max(sims[i], 0), m.knnSimPow)
                for (t, w) in c.exLinks[i] where total > 0 { K[t] += sw / Float(rank + 1) * (w / total) }
            }
        }
        lap("k近傍法", &tp)
        // 入口の点数
        var pre = [Float](repeating: 0, count: n)
        let qg = Lexical.bigrams(nq)
        if m.v || m.k {
            for i in 0..<n { pre[i] = m.wV * V[i] + m.wK * K[i] }
        } else if m.g {
            for i in 0..<n { pre[i] = Lexical.containment(qg, c.grams[i]) }
        }
        // G
        var P = [Float](repeating: 0, count: n)
        if m.g {
            var cand: [(Int, Float)] = []   // 0..<n は点、n.. は例
            for i in 0..<n { let s = pre[i] + bonus[i]; if s > 0 { cand.append((i, s)) } }
            for j in 0..<c.exText.count { let s = Lexical.containment(qg, c.exGrams[j]); if s > 0 { cand.append((n + j, s)) } }
            var frontier = Array(cand.sorted { $0.1 > $1.1 }.prefix(m.seeds))
            var a: Float = 1
            for _ in 0..<m.hops {
                a *= m.alpha
                var next: [Int: Float] = [:]
                for (node, s) in frontier {
                    if node >= n {
                        let ls = c.exLinks[node - n]
                        let total = ls.reduce(0) { $0 + $1.1 }
                        for (t, w) in ls where total > 0 { next[t] = max(next[t] ?? 0, s * m.alpha * w / total) }
                        continue
                    }
                    for e in c.adj[node] {
                        let w: Float
                        switch e.kind {
                        case 0: guard m.contains else { continue }; w = 1
                        case 1: guard m.contains && m.up else { continue }; w = 1
                        case 2: guard m.coUsed else { continue }; w = e.w * m.coWeight
                        default: guard m.coTime else { continue }; w = e.w * m.coWeight
                        }
                        let t = Int(e.to)
                        next[t] = max(next[t] ?? 0, s * m.alpha * w)
                    }
                }
                for (t, s) in next { P[t] = max(P[t], s) }
                frontier = Array(next.sorted { $0.value > $1.value }.prefix(m.seeds).map { ($0.key, $0.value) })
                _ = a
            }
        }
        lap("入口・グラフ", &tp)
        // 時間・種類
        var adjust = [Float](repeating: 0, count: n)
        if m.intents, let it = intent, !it.isEmpty {
            let folderOK = !m.folderHeadOnly || it.wantsFolder
            // 言われた期間に当てはまる物が1つも無いとき（「昨日のスクショ」が無い等）は、外れた物を消すのではなく、
            // 期間に近い日付の物ほど上に出す（-1 の代わりに、離れた日数に応じて小さく下げる）
            var nearestFallback = false
            if let r = it.range, m.timeFilter {
                let wantFam = it.families.subtracting(["folder"])
                nearestFallback = !(0..<n).contains { i in
                    guard allow?[i] ?? true, let md = c.meta[i], wantFam.isEmpty || !wantFam.isDisjoint(with: md.families) else { return false }
                    return it.download ? r.contains(md.added) : md.times.contains { r.contains($0) }
                }
            }
            for i in 0..<n {
                guard let md = c.meta[i] else { continue }
                let isFolder = md.families.contains("folder")
                if !it.families.isEmpty {
                    if !it.families.isDisjoint(with: md.families) {
                        if !isFolder { adjust[i] += m.typeBonus }
                        else if folderOK && (m.emptyFolderBonus || c.filesBelow[i] > 0) { adjust[i] += m.folderBonus }
                    }
                }
                // フォルダの中身の種類（「PDFが入ってるとこ」「スクショを分けてるフォルダ」）
                if isFolder && m.folderTypeBonus > 0 && folderOK, let fb = c.familiesBelow[i] {
                    var want = it.families.subtracting(["folder"])
                    if want.contains("screenshot") { want.insert("image") }  // スクショは名前で見分けているだけなので
                    if let hit = want.map({ fb[$0] ?? 0 }).max(), hit > 0 {
                        adjust[i] += m.folderTypeBonus * Float(hit) / Float(c.filesBelow[i])
                    }
                }
                if it.download && !md.downloaded { adjust[i] -= m.timeFilter ? 1 : 0 }
                if let r = it.range {
                    var hit = it.download ? r.contains(md.added) : md.times.contains { r.contains($0) }
                    if !hit && isFolder && m.folderTimeByChildren {
                        hit = c.adj[i].contains { e in
                            guard e.kind == 0, let cm = c.meta[Int(e.to)] else { return false }
                            return it.download ? r.contains(cm.added) : cm.times.contains { r.contains($0) }
                        }
                    }
                    if hit { adjust[i] += m.timeBonus }
                    else if nearestFallback {
                        let ts = it.download ? [md.added] : md.times
                        var gap = Int.max
                        for t in ts {
                            let d: Int = t < r.lowerBound ? r.lowerBound - t : (t > r.upperBound ? t - r.upperBound : 0)
                            if d < gap { gap = d }
                        }
                        let gapDays = Float(min(gap, 3650 * 86400)) / 86400
                        adjust[i] += m.timeBonus * 0.8 / (1 + gapDays / 3)   // 近い日付ほど、期間内に近い加点
                    }
                    else if m.timeFilter { adjust[i] -= 1 }
                }
            }
        }
        // 子が何件もそろって上位にいるフォルダを上げる（フォルダを探す言い方のときだけ）
        if m.v && m.folderCrowd > 0, let it = intent, it.wantsFolder || (!m.folderHeadOnly && it.families.contains("folder")) {
            let inTop = Set(topIndices(V, m.crowdTop))
            for i in 0..<n where c.meta[i]?.families.contains("folder") == true {
                let k = c.adj[i].filter { $0.kind == 0 && inTop.contains(Int($0.to)) }.count
                if k >= m.crowdMin { adjust[i] += m.folderCrowd * Float(k) }
            }
        }
        lap("時間・種類・フォルダ", &tp)
        // 足し合わせ
        var score = [Float](repeating: 0, count: n)
        switch m.fusion {
        case .sum:
            for i in 0..<n { score[i] = pre[i] + bonus[i] + m.wG * P[i] + adjust[i] }
        case .rrf:
            var lists: [[Float]] = []
            if m.v { lists.append(V) }
            if m.k { lists.append(K) }
            if m.g { lists.append((m.v || m.k) ? P : zip(pre, P).map { $0 + $1 }) }
            for l in lists {
                let order = l.indices.filter { l[$0] > 0 }.sorted { l[$0] > l[$1] }
                for (r, i) in order.enumerated() { score[i] += (m.rrfK + 1) / (m.rrfK + Float(r + 1)) }
            }
            for i in 0..<n { score[i] += bonus[i] + adjust[i] }
        }
        lap("足し合わせ", &tp)
        // 絞り込み（入力欄のコマンド）: 当てはまらない物は候補から外す
        if let allow {
            for i in 0..<n where !allow[i] { score[i] = -.infinity }
            defer { lap("絞り込み・上位", &tp) }
            return topIndices(score, limit).filter { allow[$0] }.map { ($0, score[$0]) }
        }
        defer { lap("絞り込み・上位", &tp) }
        return topIndices(score, limit).map { ($0, score[$0]) }
    }

    /// つながりの言い方: anchor に近い上位 N 件を入口に、contains / co_used / co_time を 1〜hops 回たどり、
    /// たどり着いた点数 ×α ＋ target との近さ ＋ 時間・種類で並べる（入口そのものは答えにしない）
    static func rankRelation(_ c: Corpus, _ it: QueryIntent, _ rel: (anchor: [Float], target: [Float]), _ m: Mix, _ limit: Int) -> [(Int, Float)] {
        let n = c.count
        let na = Lexical.normalize(it.anchor)
        var seedScore = [Float](repeating: 0, count: n)
        let aDots = c.dots(rel.anchor), tDots = c.dots(rel.target)
        let dead = c.deadCount > 0
        for i in 0..<n {
            if dead && !c.alive[i] { seedScore[i] = -.infinity; continue }
            var s = aDots[i]
            for nn in c.names[i] where na.count >= 2 && (nn.contains(na) || na.contains(nn) && nn.count >= 3) { s += m.substrBonus }
            seedScore[i] = s
        }
        let seeds = topIndices(seedScore, m.seeds)
        let seedSet = Set(seeds)
        var frontier = seeds.map { ($0, seedScore[$0]) }
        var P = [Float](repeating: 0, count: n)
        var m = m
        if let r = m.relEdges { m.contains = r.contains; m.coUsed = r.coUsed; m.coTime = r.coTime }
        if m.relByKind {
            if it.inside { m.contains = true; m.coUsed = false; m.coTime = false }
            else { m.contains = false; m.coUsed = true }
        }
        for _ in 0..<max(1, m.hops) {
            var next: [Int: Float] = [:]
            for (node, s) in frontier {
                for e in c.adj[node] {
                    let w: Float
                    switch e.kind {
                    case 0: guard m.contains else { continue }; w = 1
                    case 1: guard m.contains && !(m.relByKind && it.inside) else { continue }; w = 1
                    case 2: guard m.coUsed else { continue }; w = e.w
                    default: guard m.coTime else { continue }; w = e.w
                    }
                    let t = Int(e.to)
                    next[t] = max(next[t] ?? 0, s * m.relAlpha * w)
                }
            }
            for (t, s) in next { P[t] = max(P[t], s) }
            frontier = Array(next.sorted { $0.value > $1.value }.prefix(m.seeds).map { ($0.key, $0.value) })
        }
        var score = [Float](repeating: -9, count: n)
        for i in 0..<n where P[i] > 0 && !seedSet.contains(i) && (!dead || c.alive[i]) {
            var s = P[i] + m.relWT * tDots[i]
            if let md = c.meta[i] {
                if !it.families.isEmpty && !it.families.isDisjoint(with: md.families) {
                    s += md.families.contains("folder") ? m.folderBonus : m.typeBonus
                }
                if let r = it.range, m.timeFilter, !md.times.contains(where: { r.contains($0) }) { s -= 1 }
            }
            score[i] = s
        }
        // たどり着いた点が足りなければ、ふつうの近さ（元の文ではなく target）で埋める
        var out = topIndices(score, limit).filter { score[$0] > -9 }.map { ($0, score[$0]) }
        if out.count < limit {
            let have = Set(out.map(\.0))
            var td = tDots
            if dead { for i in 0..<n where !c.alive[i] { td[i] = -.infinity } }
            let fill = topIndices(td, limit * 2).filter { !have.contains($0) }
            out += fill.prefix(limit - out.count).map { ($0, tDots[$0] - 1) }
        }
        return out
    }

    static func topIndices(_ xs: [Float], _ k: Int) -> [Int] {
        if xs.count <= k * 4 { return Array(xs.indices.sorted { xs[$0] > xs[$1] }.prefix(k)) }
        // 部分選択（毎回全部を並べ替えない）
        var heap: [(Float, Int)] = []
        heap.reserveCapacity(k)
        for (i, x) in xs.enumerated() {
            if heap.count < k { heap.append((x, i)); if heap.count == k { heap.sort { $0.0 > $1.0 } } }
            else if x > heap[k - 1].0 {
                var j = k - 1
                heap[j] = (x, i)
                while j > 0 && heap[j - 1].0 < heap[j].0 { heap.swapAt(j, j - 1); j -= 1 }
            }
        }
        if heap.count < k { heap.sort { $0.0 > $1.0 } }
        return heap.map(\.1)
    }
}

/// 文字の重なり・読み（ベクトルを使わない側）
public enum Lexical {
    public static func normalize(_ s: String) -> String { Describe.normalize(s) }

    /// 2 文字ずつの組。ひらがなだけの組（「やつ」「のと」）は中身が無いので捨てる
    static func bigrams(_ s: String) -> Set<String> {
        let cs = Array(s.filter { !$0.isWhitespace && !"_-.・、。「」()（）".contains($0) })
        var out = Set<String>()
        if cs.count < 2 { return out }
        for i in 0..<(cs.count - 1) {
            let a = cs[i], b = cs[i + 1]
            if isHira(a) && isHira(b) { continue }
            out.insert(String([a, b]))
        }
        return out
    }

    static func isHira(_ c: Character) -> Bool {
        guard let u = c.unicodeScalars.first?.value else { return false }
        return (0x3041...0x309F).contains(u) || c == "ー"
    }

    /// 入力の組のうち、名前に入っている割合
    static func containment(_ q: Set<String>, _ t: Set<String>) -> Float {
        if q.isEmpty || t.isEmpty { return 0 }
        return Float(q.intersection(t).count) / Float(q.count)
    }

    /// 日本語の読みをローマ字に（CFStringTokenizer の LatinTranscription。漢字も読む）
    public static func romaji(_ s: String) -> String {
        let cf = s as CFString
        guard let tok = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: CFStringGetLength(cf)),
                                                kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale) else { return "" }
        var out = ""
        while !CFStringTokenizerAdvanceToNextToken(tok).isEmpty {
            if let r = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String {
                out += r
            }
        }
        return out.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// ヘボン式・訓令式・長音の違いを揃える（mitsumori / mitumori、seikyuusho / seikyusyo）
    public static func canonRomaji(_ s: String) -> String {
        var t = s.lowercased().filter { $0.isLetter || $0.isNumber }
        for (a, b) in [("tsu", "tu"), ("shi", "si"), ("chi", "ti"), ("sha", "sya"), ("shu", "syu"), ("sho", "syo"),
                       ("cha", "tya"), ("chu", "tyu"), ("cho", "tyo"), ("ja", "zya"), ("ju", "zyu"), ("jo", "zyo"),
                       ("ji", "zi"), ("fu", "hu"), ("sh", "sy"), ("ch", "ty"), ("ou", "o"), ("uu", "u"), ("aa", "a"),
                       ("ii", "i"), ("ee", "e"), ("oo", "o"), ("nn", "n")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    /// q が t のどこかの部分に「何文字の直しで」一致するか（Sellers のアルゴリズム）
    public static func approxSubstringDistance(_ q: String, in t: String) -> Int {
        let a = Array(q.utf8)
        if a.isEmpty { return 0 }
        if a.count <= 64 {
            var t = t
            return t.withUTF8 { Myers(a).distance($0) }
        }
        return approxSubstringDistanceDP(a, Array(t.utf8))
    }

    /// 前の作り（Sellers の表を 1 列ずつ）。64 バイトを超える入力と、ビット並列の版の確かめ用
    public static func approxSubstringDistanceDP(_ a: [UInt8], _ b: [UInt8]) -> Int {
        if a.isEmpty { return 0 }
        var prev = Array(0...a.count)
        var best = prev[a.count]
        for j in 0..<b.count {
            var cur = [Int](repeating: 0, count: a.count + 1)
            for i in 1...a.count {
                cur[i] = min(prev[i] + 1, cur[i - 1] + 1, prev[i - 1] + (a[i - 1] == b[j] ? 0 : 1))
            }
            best = min(best, cur[a.count])
            prev = cur
        }
        return best
    }
}
