import AppKit
import Foundation

/// アプリの並べ方の既定（raiden-eval の --sweep / --combos の結果で決めた。README 参照）
public extension Mix {
    /// アプリ: V+K の重みつきの和（k=5、重み 1.25、例の票は近さの 6 乗）＋名前の文字一致
    ///   近さの 6 乗: 近い例（同じ言い方を選び直した 0.9 以上）はほぼそのまま効き、0.6 前後の遠い例は 0.05 ほどに弱まる。
    ///   例が標準アプリの分しか無いとき、遠い例の票が自作アプリを押し負かすのを避ける（raiden-eval --sweep-knn、README 参照）
    static var appDefault: Mix {
        var m = Mix()
        m.v = true; m.k = true; m.g = false; m.fusion = .sum
        m.knnK = 5; m.wK = 1.25; m.knnMinSim = 0; m.knnSimPow = 6
        m.prefixBonus = 0.6; m.substrBonus = 0.35; m.fuzzyBonus = 0
        return m
    }
    /// ファイル・フォルダ（raiden-eval --files で決めた。README 参照）
    ///   V+K の和（K は重み 0.3・近さ 0.6 未満の例は数えない）＋時間・種類の絞り込み
    ///   フォルダ: 入力の一番後ろの種類の言葉がフォルダの言葉のときだけ、中にファイルのあるフォルダに +0.3、
    ///   中の種類が合う割合 × 0.2、子が近さの上位 20 件に 2 件以上なら 1 件ごとに +0.01（Mix の folder* の既定値）。
    ///   時間の言葉はフォルダなら中の物の日付でも当たり
    ///   「A と同じ日の B」「A の中の B」は A/B に分け、A の上位 5 件から co_used を 2 回たどる
    static var fileDefault: Mix {
        var m = Mix()
        m.v = true; m.k = true; m.g = false; m.fusion = .sum
        m.wK = 0.3; m.knnMinSim = 0.6
        m.intents = true; m.folderBonus = 0.3
        m.relation = true; m.seeds = 5; m.hops = 2; m.relAlpha = 0.5; m.relWT = 1.0
        m.contains = false; m.coUsed = true; m.coTime = false
        m.alpha = 0.2
        return m
    }
}

/// 例の点（入力文）と、そこから chose の線でつながったアプリ
public struct ExampleNode: Sendable {
    public struct Link: Sendable {
        public var appKey: String
        public var weight: Float   // 選んだ回数
        public var lastUsed: Int
        public init(appKey: String, weight: Float = 1, lastUsed: Int = 0) {
            self.appKey = appKey; self.weight = weight; self.lastUsed = lastUsed
        }
    }
    public var q: String
    public var links: [Link]
    public init(q: String, links: [Link]) { self.q = q; self.links = links }
}

public struct SearchResult: Sendable {
    public let app: AppEntry
    public let score: Float
}

public struct FileResult: Sendable {
    public let file: FileEntry
    public let score: Float
    public init(file: FileEntry, score: Float) { self.file = file; self.score = score }
}

/// 検索の本体。アプリも答え合わせ（raiden-eval）もこれを通す。
/// 近さはメモリに載せたベクトルとの総当たりの内積（数千件なら十分速い）。並べ方は Ranker（Mix で組み合わせを選ぶ）。
public final class Engine {
    public let embedder: Embedder
    public var appMix = Mix.appDefault
    /// 入力に種類の言葉（PDF・ワード・画像…）があるとき、手元のその種類をいちばん多く開くアプリに足す点
    /// （raiden-eval --sweep-open で決めた。0.05〜0.3 で既存 25 問の例ありは変わらず、自作アプリは大きいほど上がる）
    public var openBonus: Float = 0.15
    public var fileMix = Mix.fileDefault
    public let useDict: Bool
    public let store: Store?
    private let lock = NSLock()
    private(set) public var apps: [AppEntry] = []
    private var appVecs: [[Float]] = []
    private var byKey: [String: Int] = [:]
    private var topOpener: [String: Int] = [:]  // 種類 → その種類をいちばん多く開くアプリの番号
    private(set) public var examples: [ExampleNode] = []
    private var exVecs: [[Float]] = []
    private var appCorpus = Corpus()
    private(set) public var files: [FileEntry] = []
    private var fileCorpus = Corpus()
    private var fileIndex: [String: Int] = [:]
    private var fileKeys: [QueryFilters.FileKeys] = []
    private var ctxCache: FilterContext?   // filterContext の作り置き（setFiles で捨てる）
    private var fileBases: [String] = []    // 中身を読まない分の説明文（files と同じ並び）
    private var targetStamps: [String] = [] // 最終の説明文の stamp
    private var fileStamps: [String] = []   // いまメモリにあるベクトルの stamp（"" はまだ無い、:s 付きは短い説明だけ）

    public init(embedder: Embedder, store: Store? = nil, useDict: Bool = true) {
        self.embedder = embedder
        self.store = store
        self.useDict = useDict
    }

    /// opens を渡すと、グラフの線 app → file（opens）も Store に張り直す
    public func setApps(_ list: [AppEntry], opens: OpenWithIndex? = nil) {
        if let store, let opens { store.replaceOpens(opens.pairs, apps: list) }
        var top: [String: (Int, Int)] = [:]
        for (i, a) in list.enumerated() {
            for (f, n) in a.opens where n > (top[f]?.1 ?? 0) { top[f] = (i, n) }
        }
        let descs = list.map { Describe.text($0, useDict: useDict) }
        let vs: [[Float]]
        if let store {
            vs = store.appVectors(list, descriptions: descs, model: embedder.identifier) { embedder.embed($0) }
        } else {
            vs = descs.map { embedder.embed($0) }
        }
        lock.lock()
        apps = list; appVecs = vs
        topOpener = top.mapValues(\.0)
        byKey = Dictionary(list.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })
        rebuildAppCorpus()
        lock.unlock()
    }

    /// 保存済みの例を読み込む（Store があるとき）
    public func loadExamples() {
        guard let store else { return }
        let rows = store.examples(model: embedder.identifier) { embedder.embed($0) }
        lock.lock()
        examples = rows.map(\.0); exVecs = rows.map(\.1)
        rebuildAppCorpus()
        lock.unlock()
    }

    /// メモリ上に例を足す（答え合わせ用。保存しない）。pairs は（入力文, アプリのキー）
    public func addExamples(_ pairs: [(String, String)]) {
        var grouped: [String: [ExampleNode.Link]] = [:]
        var order: [String] = []
        for (q, k) in pairs where !q.isEmpty && !k.isEmpty {
            if grouped[q] == nil { order.append(q) }
            grouped[q, default: []].append(.init(appKey: k))
        }
        let nodes = order.map { ExampleNode(q: $0, links: grouped[$0]!) }
        let vs = nodes.map { embedder.embed($0.q) }
        lock.lock()
        examples += nodes; exVecs += vs
        rebuildAppCorpus()
        lock.unlock()
    }

    /// 選んで開いた組を覚える（Store に保存し、メモリにも足す）
    public func learn(query: String, app: AppEntry) {
        let q = query.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let v = embedder.embed(q)
        store?.recordChoice(query: q, app: app, appDescription: Describe.text(app, useDict: useDict),
                            vector: v, model: embedder.identifier)
        let now = Int(Date().timeIntervalSince1970)
        lock.lock()
        if let i = examples.firstIndex(where: { $0.q == q }) {
            if let j = examples[i].links.firstIndex(where: { $0.appKey == app.key }) {
                examples[i].links[j].weight += 1
                examples[i].links[j].lastUsed = now
            } else {
                examples[i].links.append(.init(appKey: app.key, weight: 1, lastUsed: now))
            }
        } else {
            examples.append(ExampleNode(q: q, links: [.init(appKey: app.key, weight: 1, lastUsed: now)]))
            exVecs.append(v)
        }
        rebuildAppCorpus()
        lock.unlock()
    }

    /// lock を持った状態で呼ぶ
    private func rebuildAppCorpus() {
        var c = Corpus()
        c.setItems(names: apps.map { [$0.jp, $0.name, String(($0.path as NSString).lastPathComponent.dropLast(4))] }, vecs: appVecs)
        for (ex, v) in zip(examples, exVecs) {
            c.addExample(text: ex.q, vec: v, links: ex.links.compactMap { l in byKey[l.appKey].map { ($0, l.weight) } })
        }
        appCorpus = c
    }

    public func search(_ query: String, limit: Int = 8, useExamples: Bool = true) -> [SearchResult] {
        searchJudged(query, limit: limit, useExamples: useExamples).results
    }

    /// search と同じ並びに「見つからない」の印を付けて返す（弾いても候補は消さない）
    public func searchJudged(_ query: String, limit: Int = 8, useExamples: Bool = true) -> Judged<SearchResult> {
        let q = query.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return Judged(results: [], noMatch: false, signals: MatchSignals()) }
        var m = appMix
        if !useExamples { m.k = false }
        // 入力欄のコマンド（#type app #name …）。コマンドが無ければ今までどおり
        let f = QueryFilters.parse(query.precomposedStringWithCanonicalMapping)
        guard f.hasSyntax else { return rankAppsJudged(query: q, vec: embedder.embed(q), mix: m, limit: limit) }
        var none = Judged<SearchResult>(results: [], noMatch: false, signals: MatchSignals())
        none.filters = f
        guard f.allowsApps, f.isActive || !f.text.isEmpty else { return none }
        lock.lock()
        let list = apps
        lock.unlock()
        let allow = f.isActive ? list.map { f.matches(app: $0) } : nil
        if f.text.isEmpty {
            // 言葉が無ければ当てはまるアプリを名前の順に
            var j = Judged(results: list.indices.filter { allow?[$0] ?? true }.sorted { list[$0].jp < list[$1].jp }
                .prefix(limit).map { SearchResult(app: list[$0], score: 0) }, noMatch: false, signals: MatchSignals())
            j.filters = f
            return j
        }
        var j = rankAppsJudged(query: f.text, vec: embedder.embed(f.text), mix: m, limit: limit, allow: allow)
        j.filters = f
        return j
    }

    /// ベクトルを作り済みの入力で並べる（答え合わせで組み合わせを振るとき用）
    public func rankApps(query q: String, vec: [Float], mix: Mix, limit: Int = 8) -> [SearchResult] {
        rankAppsJudged(query: q, vec: vec, mix: mix, limit: limit).results
    }

    /// Ranker で並べ、いつも開くアプリの加点を足して並べ直す（lock の外で呼ぶ）
    private func rankedApps(_ c: Corpus, top: [String: Int], count: Int, query q: String, vec: [Float], mix: Mix, limit: Int,
                            allow: [Bool]? = nil) -> [(Int, Float)] {
        // いつも開くアプリの加点: 全部並べてから足して並べ直す（アプリは百数十個なので軽い）
        let boost = openBonus > 0 ? Set(QueryIntent.parse(q).families.compactMap { top[$0] }) : []
        if boost.isEmpty { return Ranker.rank(c, query: q, vec: vec, mix: mix, limit: limit, allow: allow) }
        return Array(Ranker.rank(c, query: q, vec: vec, mix: mix, limit: count, allow: allow)
            .map { ($0.0, $0.1 + (boost.contains($0.0) ? openBonus : 0)) }
            .sorted { $0.1 > $1.1 }.prefix(limit))
    }

    /// Raiden からファイルを開いたとき、実際に開いたアプリを覚える（file → app の opened_with の線）
    public func recordOpened(file path: String, appURL: URL?) {
        guard let store else { return }
        let app = appURL ?? NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path))
        guard let app else { return }
        let key = Bundle(url: app)?.bundleIdentifier ?? app.standardizedFileURL.path
        // 点の名前は replaceOpens と同じ日本語名にそろえる（一覧に無いアプリだけ .app の名前）
        lock.lock()
        let name = byKey[key].map { apps[$0].jp } ?? app.deletingPathExtension().lastPathComponent
        lock.unlock()
        store.recordOpenedWith(file: path, appKey: key, appName: name)
    }

    public func rankAppsJudged(query q: String, vec: [Float], mix: Mix, limit: Int = 8, rule: NoMatchRule = .apps,
                               allow: [Bool]? = nil) -> Judged<SearchResult> {
        lock.lock()
        let c = appCorpus, apps = self.apps, top = topOpener
        lock.unlock()
        let ok = allow.map { $0.count == apps.count ? $0 : Array(repeating: true, count: apps.count) }
        let ranked = rankedApps(c, top: top, count: apps.count, query: q, vec: vec, mix: mix, limit: max(limit, 3), allow: ok)
        if ranked.isEmpty { return Judged(results: [], noMatch: allow != nil, signals: MatchSignals()) }
        let s = NoMatch.signals(c, query: q, vec: vec, mix: mix, ranked: ranked, rankedNoEx: nil, intent: nil, relation: false, allow: ok)
        return Judged(results: ranked.prefix(limit).map { SearchResult(app: apps[$0.0], score: $0.1) },
                      noMatch: rule.isNoMatch(s), signals: s)
    }

    // MARK: - ファイル・フォルダ

    /// ベクトル化の残り。short はまだベクトルが無い物（名前・場所・種類の短い説明でまず作る）、
    /// full は短い説明のベクトルしか無く、中身の頭を入れた説明文で作り直す物。どちらもパス
    public struct FilePending: Sendable {
        public var short: [String] = []
        public var full: [String] = []
        public var isEmpty: Bool { short.isEmpty && full.isEmpty }
        public init() {}
    }

    /// ファイル・フォルダの点を入れて、作るべきベクトルを返す（ベクトル化はしない。embedFiles で裏で進める）。
    /// 保存済みのベクトル（説明文の元・日付・大きさが同じ物）はそのまま使い、無い物はベクトル無し（近さ 0）で入れる。
    /// ファイル・フォルダのベクトルはメモリにも DB にも 2 値（128 バイト、BinVec）だけを持つ。
    /// 0 の物も名前の文字一致（ローマ字・打ち間違いも）と絞り込みのコマンドでは候補に出る。
    /// contains（フォルダ → 中の物）・co_used・co_time の線もここで張る
    public func installFiles(_ entries: [FileEntry]) -> FilePending {
        let cm = FileCatalog.childrenMap(entries)
        let bases = entries.map { FileCatalog.baseDescription($0, children: cm[$0.path] ?? []) }
        let model = embedder.identifier
        let stamps = zip(entries, bases).map { Store.hash("\(model)\n\($1)\n\($0.mtime) \($0.size)") }
        let have = store?.storedFileCodes() ?? [:]
        let zero = [UInt8](repeating: 0, count: BinVec.bytes)
        var codes: [UInt8] = []
        codes.reserveCapacity(entries.count * BinVec.bytes)
        var present: [Bool] = []
        present.reserveCapacity(entries.count)
        var pending = FilePending()
        var newNodes: [(entry: FileEntry, code: [UInt8]?, hash: String)] = []
        lock.lock()
        let prior = Dictionary(files.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
        let priorStamps = fileStamps, priorCorpus = fileCorpus
        lock.unlock()
        for (i, e) in entries.enumerated() {
            // メモリにあれば使う（Store なしの答え合わせ・保存前の物）
            if let j = prior[e.path], j < priorStamps.count, j < priorCorpus.count, priorCorpus.isBinary, priorCorpus.present[j] {
                let ps = priorStamps[j]
                if ps == stamps[i] || ps == stamps[i] + Self.shortMark {
                    codes += priorCorpus.code(j); present.append(true)
                    if ps != stamps[i] { pending.full.append(e.path) }
                    continue
                }
            }
            if let h = have[e.path], h.code.count == BinVec.bytes, h.hash == stamps[i] || h.hash == stamps[i] + Self.shortMark {
                codes += h.code; present.append(true)
                if h.hash != stamps[i] { pending.full.append(e.path) }
                continue
            }
            codes += zero; present.append(false)
            pending.short.append(e.path)
            if FileCatalog.hasContent(e) { pending.full.append(e.path) }
            if have[e.path] == nil { newNodes.append((e, nil, "")) }
        }
        // まだベクトルの無い物も点だけ作っておく（線を張るため）。消えた物の点は消す
        store?.saveFileNodes(newNodes)
        let live = Set(entries.map(\.path))
        store?.deleteFileNodes(have.keys.filter { !live.contains($0) })
        // メモリのベクトルの stamp: まだ無い物は ""、短い説明だけの物は :s 付き
        let fullSet = Set(pending.full), shortSet = Set(pending.short)
        let memStamps = entries.indices.map { i -> String in
            let p = entries[i].path
            return shortSet.contains(p) ? "" : fullSet.contains(p) ? stamps[i] + Self.shortMark : stamps[i]
        }
        let contains = FileCatalog.containsEdges(entries)
        let co = FileCatalog.coUsedEdges(entries)
        let ct = FileCatalog.coTimeEdges(entries)
        if let store {
            store.replaceFileEdges(kind: "contains", contains.map { (entries[$0.0].path, entries[$0.1].path, 1) })
            store.replaceFileEdges(kind: "co_used", co.map { (entries[$0.0].path, entries[$0.1].path, $0.2) })
            store.replaceFileEdges(kind: "co_time", ct.map { (entries[$0.0].path, entries[$0.1].path, $0.2) })
        }
        var c = Corpus()
        c.setItems(names: entries.map { [$0.stem] }, codes: codes, present: present, meta: entries.map {
            Corpus.Meta(families: Set($0.families), times: [$0.lastUsed, $0.mtime, $0.added].filter { $0 > 0 },
                        added: $0.added, downloaded: $0.downloaded)
        })
        c.addEdges(contains: contains, coUsed: co, coTime: ct)
        let keys = entries.map(QueryFilters.FileKeys.init)
        lock.lock()
        files = entries
        fileKeys = keys
        fileBases = bases
        fileStamps = memStamps
        targetStamps = stamps
        ctxCache = nil
        fileIndex = Dictionary(entries.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
        fileCorpus = c
        lock.unlock()
        return pending
    }

    /// 短い説明だけで作ったベクトルの印（desc_hash の後ろに付ける）
    static let shortMark = ":s"
    /// まとめてベクトル化する件数（raiden-eval --bench-embed で決めた。8 と 16 は 1 件あたりほぼ同じで、
    /// 8 のほうが裏で作っている間の検索の待ちが短い。README 参照）
    public var embedBatchSize = 8

    /// paths のベクトルを作って Corpus と Store に入れる。full なら中身の頭まで入れた説明文、でなければ名前・場所・種類の短い説明。
    /// 中身を読まない種類（画像・フォルダ…）は短い説明がそのまま最終の説明文。一覧が変わって消えた・変わった物は飛ばす。作った数を返す
    @discardableResult
    public func embedFiles(_ paths: [String], full: Bool) -> Int {
        lock.lock()
        let items: [(String, FileEntry, String, String)] = paths.compactMap { p in
            guard let i = fileIndex[p], i < fileBases.count else { return nil }
            return (p, files[i], fileBases[i], targetStamps[i])
        }
        lock.unlock()
        guard !items.isEmpty else { return 0 }
        let descs = items.map { it -> String in
            guard full else { return it.2 }
            let c = FileCatalog.content(it.1)
            return c.isEmpty ? it.2 : it.2 + " 中身: " + c
        }
        let vs = embedder.embedBatch(descs, batch: embedBatchSize)
        var rows: [(entry: FileEntry, code: [UInt8]?, hash: String)] = []
        lock.lock()
        for (k, it) in items.enumerated() where vs[k].contains(where: { $0 != 0 }) {
            let done = full || !FileCatalog.hasContent(it.1)
            let h = done ? it.3 : it.3 + Self.shortMark
            let code = BinVec.encode(vs[k])
            rows.append((it.1, code, h))
            // 待っている間に一覧が入れ替わっていたら、同じ物（同じ stamp）のときだけ入れる
            guard let i = fileIndex[it.0], i < targetStamps.count, targetStamps[i] == it.3 else { continue }
            fileCorpus.setCode(i, code)
            fileStamps[i] = h
        }
        lock.unlock()
        store?.saveFileNodes(rows)
        return rows.count
    }

    /// ファイル・フォルダの点を入れ、ベクトルを全部作ってから返す（答え合わせ・確かめ用。アプリは installFiles と embedFiles で裏で進める）。
    /// full: false なら短い説明だけ。作り直した数を返す
    @discardableResult
    public func setFiles(_ entries: [FileEntry], full: Bool = true, progress: ((Int, Int) -> Void)? = nil) -> Int {
        let p = installFiles(entries)
        let total = p.short.count + (full ? p.full.count : 0)
        if total > 0 { progress?(0, total) }
        var made = 0
        let step = max(embedBatchSize * 4, 64)
        for (list, f) in [(p.short, false), (full ? p.full : [], true)] {
            var i = 0
            while i < list.count {
                let part = Array(list[i..<min(i + step, list.count)])
                i += part.count
                embedFiles(part, full: f)
                made += part.count
                progress?(made, total)
            }
        }
        return Set(p.short + (full ? p.full : [])).count
    }

    /// 一覧に入っているパスか
    public func hasFile(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return fileIndex[path] != nil }

    /// ファイルの例（入力文, パス）をメモリに足す（答え合わせ用）
    public func addFileExamples(_ pairs: [(String, String)]) {
        let vs = pairs.map { embedder.embed($0.0) }
        lock.lock()
        for ((q, p), v) in zip(pairs, vs) {
            guard let i = fileIndex[p] else { continue }
            fileCorpus.addExample(text: q, vec: v, links: [(i, 1)])
        }
        lock.unlock()
    }

    /// いまのファイルの Corpus（答え合わせで件数を増やして試す用）
    public var fileCorpusSnapshot: Corpus { lock.lock(); defer { lock.unlock() }; return fileCorpus }

    public func clearFileExamples() { lock.lock(); fileCorpus.clearExamples(); lock.unlock() }

    public var fileEdgeCounts: (contains: Int, coUsed: Int, coTime: Int) {
        lock.lock(); defer { lock.unlock() }
        var a = 0, b = 0, c = 0
        for es in fileCorpus.adj { for e in es { if e.kind == 0 { a += 1 } else if e.kind == 2 { b += 1 } else if e.kind == 3 { c += 1 } } }
        return (a, b / 2, c / 2)
    }

    public func searchFiles(_ query: String, limit: Int = 8, now: Date = Date()) -> [FileResult] {
        searchFilesJudged(query, limit: limit, now: now).results
    }

    /// searchFiles と同じ並びに「見つからない」の印を付けて返す（弾いても候補は消さない）
    /// 値の候補の件数を数えるための手元の一覧（入力欄の「-」の一覧で使う）
    public var filterContext: FilterContext {
        lock.lock()
        if let c = ctxCache, c.appCount == apps.count { lock.unlock(); return c }
        let fs = files, keys = fileKeys, n = apps.count
        lock.unlock()
        let c = FilterContext(files: fs, keys: keys.count == fs.count ? keys : nil, appCount: n)
        lock.lock(); if fs.count == files.count { ctxCache = c }; lock.unlock()
        return c
    }

    public func searchFilesJudged(_ query: String, limit: Int = 8, now: Date = Date()) -> Judged<FileResult> {
        let q = query.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return Judged(results: [], noMatch: false, signals: MatchSignals()) }
        // 入力欄のコマンド（#kind ss #date 7d …）。コマンドが無ければ今までどおり
        let f = QueryFilters.parse(query.precomposedStringWithCanonicalMapping, now: now)
        if f.hasSyntax { return searchFilesFiltered(f, limit: limit, now: now) }
        let it = QueryIntent.parse(q, now: now)
        var rel: ([Float], [Float])?
        if fileMix.relation && it.hasRelation {
            rel = (embedder.embed(it.anchor), embedder.embed(it.target.isEmpty ? q : it.target))
        }
        return rankFilesJudged(query: q, vec: embedder.embed(q), mix: fileMix, intent: it, rel: rel, limit: limit)
    }

    /// コマンド付きの入力: 当てはまる物だけを候補にする（確実な絞り込み）。
    /// 残りの文が空なら新しい順（使った日・変更日の新しい方）。「見つからない」の判定は残った物の中で行う。
    /// 当てはまる物が 0 件なら results は空で noMatch（画面は「条件に合う物はありません」）
    func searchFilesFiltered(_ f: QueryFilters, limit: Int, now: Date) -> Judged<FileResult> {
        var none = Judged<FileResult>(results: [], noMatch: false, signals: MatchSignals())
        none.filters = f
        guard f.allowsFiles, f.isActive || !f.text.isEmpty else { return none }
        lock.lock()
        let fs = files, keys = fileKeys
        lock.unlock()
        let allow: [Bool]? = f.isActive ? fs.indices.map { f.matches(fs[$0], keys: keys.count == fs.count ? keys[$0] : nil) } : nil
        if let allow, !allow.contains(true) { none = Judged(results: [], noMatch: true, signals: MatchSignals()); none.filters = f; return none }
        var j: Judged<FileResult>
        if f.text.isEmpty {
            let order = fs.indices.filter { allow?[$0] ?? true }.sorted {
                let a = max(fs[$0].lastUsed, fs[$0].mtime), b = max(fs[$1].lastUsed, fs[$1].mtime)
                return a != b ? a > b : fs[$0].path < fs[$1].path
            }
            j = Judged(results: order.prefix(limit).map { FileResult(file: fs[$0], score: 0) }, noMatch: false, signals: MatchSignals())
        } else {
            let t = f.text
            let it = QueryIntent.parse(t, now: now)
            var rel: ([Float], [Float])?
            if fileMix.relation && it.hasRelation { rel = (embedder.embed(it.anchor), embedder.embed(it.target.isEmpty ? t : it.target)) }
            j = rankFilesJudged(query: t, vec: embedder.embed(t), mix: fileMix, intent: it, rel: rel, limit: limit, allow: allow)
        }
        j.filters = f
        return j
    }

    public func rankFiles(query q: String, vec: [Float], mix: Mix, intent: QueryIntent?,
                          rel: (anchor: [Float], target: [Float])? = nil, limit: Int = 8) -> [FileResult] {
        lock.lock()
        let c = fileCorpus, fs = files
        lock.unlock()
        let relation = mix.relation && (intent?.hasRelation ?? false) && rel != nil
        var ranked = Ranker.rank(c, query: q, vec: vec, mix: mix, intent: intent, rel: rel, limit: max(limit, rerankN))
        // つながりの言い方は target との近さ（重み relWT）で点数を付けているので、そちらを並べ直す
        if Self.worthRerank(q) {
            ranked = relation ? rerank(ranked, c: c, vec: rel!.target, wV: mix.relWT) : rerank(ranked, c: c, vec: vec, wV: mix.wV)
        }
        return ranked.prefix(limit).map { FileResult(file: fs[$0.0], score: $0.1) }
    }

    /// 並べ直す件数（0 なら並べ直さない）。上位 rerankN 件だけ、その場で説明文を作り直して bge-m3 でベクトル化し、
    /// 2 値の近さとの差を点数に足して並べ直す（ディスクに細かいベクトルを置かない並べ直し）。作ったベクトルはメモリに少しだけ覚える
    public var rerankN = 10

    /// 打ちかけの短い入力（英数字 3 文字まで・1 文字）は並べ直さない（名前の一致で決まり、上位が 1 文字ごとに入れ替わって毎回作り直しになる）
    static func worthRerank(_ q: String) -> Bool {
        let n = Lexical.normalize(q).filter { !$0.isWhitespace }
        return n.allSatisfy(\.isASCII) ? n.count >= 4 : n.count >= 2
    }
    private var exactCache: [String: [Float]] = [:]
    private let exactLock = NSLock()
    static let exactCapacity = 2048

    private func rerank(_ ranked: [(Int, Float)], c: Corpus, vec: [Float], wV: Float) -> [(Int, Float)] {
        rerankExact(ranked, c: c, vec: vec, wV: wV).0
    }

    /// 並べ直した結果と、その場で作ったベクトルとの近さ（添字 → cos。見つからない判定の手がかりに使う）
    private func rerankExact(_ ranked: [(Int, Float)], c: Corpus, vec: [Float], wV: Float) -> ([(Int, Float)], [Int: Float]) {
        guard rerankN > 0, c.isBinary, !ranked.isEmpty else { return (ranked, [:]) }
        let top = Array(ranked.prefix(rerankN))
        lock.lock()
        let keys = top.map { $0.0 < targetStamps.count ? files[$0.0].path + "\n" + targetStamps[$0.0] : "" }
        let items = top.map { $0.0 < files.count ? (files[$0.0], fileBases[$0.0]) : nil }
        lock.unlock()
        exactLock.lock()
        var vs = keys.map { exactCache[$0] }
        exactLock.unlock()
        let miss = vs.indices.filter { vs[$0] == nil && items[$0] != nil }
        if !miss.isEmpty {
            let descs = miss.map { k -> String in
                let (e, b) = items[k]!
                let ct = FileCatalog.content(e)
                return ct.isEmpty ? b : b + " 中身: " + ct
            }
            let made = (embedder as? UrgentEmbedder)?.embedUrgent(descs, batch: embedBatchSize) ?? embedder.embedBatch(descs, batch: embedBatchSize)
            exactLock.lock()
            if exactCache.count > Self.exactCapacity { exactCache.removeAll(keepingCapacity: true) }
            for (j, k) in miss.enumerated() where made[j].contains(where: { $0 != 0 }) { vs[k] = made[j]; exactCache[keys[k]] = made[j] }
            exactLock.unlock()
        }
        var out = ranked
        var exact: [Int: Float] = [:]
        for (k, (i, s)) in top.enumerated() {
            guard let v = vs[k] else { continue }
            let approx = c.present[i] ? BinVec.asymScore(c.code(i), q: vec) : 0
            let x = Vec.dot(v, vec)
            exact[i] = x
            out[k] = (i, s + wV * (x - approx))
        }
        return (out.sorted { $0.1 > $1.1 }, exact)
    }

    public func rankFilesJudged(query q: String, vec: [Float], mix: Mix, intent: QueryIntent?,
                                rel: (anchor: [Float], target: [Float])? = nil, limit: Int = 8,
                                rule: NoMatchRule = .files, allow: [Bool]? = nil) -> Judged<FileResult> {
        lock.lock()
        let c = fileCorpus, fs = files
        lock.unlock()
        let allow = allow.flatMap { $0.count == fs.count ? $0 : nil }
        let relation = mix.relation && (intent?.hasRelation ?? false) && rel != nil
        var ranked = Ranker.rank(c, query: q, vec: vec, mix: mix, intent: intent, rel: rel, limit: max(limit, 3, rerankN), allow: allow)
        var exact: [Int: Float] = [:]
        let doRerank = Self.worthRerank(q)
        if doRerank && relation { ranked = rerank(ranked, c: c, vec: rel!.target, wV: mix.relWT) }
        else if doRerank { (ranked, exact) = rerankExact(ranked, c: c, vec: vec, wV: mix.wV) }
        // 1 位と 2 位の差は例を抜いて見る（弱い例が 1 件だけ点数を押し上げて差が開くのを避ける。並べ替えは 1ms ほど）
        var noEx: [(Int, Float)]?
        if mix.k && !c.exVecs.isEmpty && !relation {
            var m0 = mix; m0.k = false
            noEx = Ranker.rank(c, query: q, vec: vec, mix: m0, intent: intent, rel: rel, limit: max(2, rerankN), allow: allow)
            if doRerank { noEx = rerank(noEx!, c: c, vec: vec, wV: m0.wV) }   // 作ったベクトルは覚えているので軽い
        }
        let s = NoMatch.signals(c, query: q, vec: vec, mix: mix, ranked: ranked, rankedNoEx: noEx, intent: intent, relation: relation,
                                allow: allow, exact: exact)
        return Judged(results: ranked.prefix(limit).map { FileResult(file: fs[$0.0], score: $0.1) },
                      noMatch: rule.isNoMatch(s), signals: s)
    }
}

public enum RaidenPaths {
    public static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Raiden", isDirectory: true)
    }
}

/// いまのプロセスのメモリ（アクティビティモニタの「メモリ」と同じ phys_footprint）
public func physFootprintMB() -> Double { vmInfo().map { Double($0.phys_footprint) / 1_048_576 } ?? -1 }

/// 実メモリに載っているページ（mmap した重みのような、読み直せるファイルのページも含む）
public func residentMB() -> Double { vmInfo().map { Double($0.resident_size) / 1_048_576 } ?? -1 }

func vmInfo() -> task_vm_info_data_t? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info : nil
}
