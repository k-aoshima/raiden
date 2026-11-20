import AppKit
import Foundation

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
    public init(app: AppEntry, score: Float) { self.app = app; self.score = score }
}

public struct FileResult: Sendable {
    public let file: FileEntry
    public let score: Float
    public init(file: FileEntry, score: Float) { self.file = file; self.score = score }
}

/// 検索の本体。アプリも答え合わせ（raiden-eval）もこれを通す。埋め込みモデルは使わない。
///   アプリ: 名前・辞書（AppDict・app-notes.json・README などの言葉）・「選んだ」記録の文字の一致（Ranker）＋いつも開く・最近使った加点
///   ファイル・フォルダ: Spotlight に問い合わせる（SpotlightSearch）
public final class Engine {
    public var appMix = Mix()
    /// 入力に種類の言葉（PDF・ワード・画像…）があるとき、手元のその種類をいちばん多く開くアプリに足す点
    public var openBonus: Float = 0.15
    /// 最近使ったアプリに足す点の最大（30 日で 1/e）。名前・辞書・記録に当たらないときの並びも決める
    public var recentBonus: Float = 0.05
    public let useDict: Bool
    public let store: Store?
    public let spotlight: SpotlightSearch
    private let lock = NSLock()
    private(set) public var apps: [AppEntry] = []
    private var byKey: [String: Int] = [:]
    private var topOpener: [String: Int] = [:]  // 種類 → その種類をいちばん多く開くアプリの番号
    private(set) public var examples: [ExampleNode] = []
    private var index = AppIndex()

    public init(store: Store? = nil, useDict: Bool = true, exclude: ScanScope = ScanScope(roots: [])) {
        self.store = store
        self.useDict = useDict
        spotlight = SpotlightSearch(exclude: exclude)
        if let store {
            spotlight.examples = { store.fileExamples() }
            spotlight.coUsed = { store.coUsed($0) }
        }
    }

    public func setApps(_ list: [AppEntry]) {
        var top: [String: (Int, Int)] = [:]
        for (i, a) in list.enumerated() {
            for (f, n) in a.opens where n > (top[f]?.1 ?? 0) { top[f] = (i, n) }
        }
        lock.lock()
        apps = list
        topOpener = top.mapValues(\.0)
        byKey = Dictionary(list.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })
        rebuildIndex()
        lock.unlock()
    }

    /// 保存済みの「選んだ」記録を読み込む（Store があるとき）
    public func loadExamples() {
        guard let store else { return }
        let rows = store.examples()
        lock.lock()
        examples = rows
        rebuildIndex()
        lock.unlock()
    }

    /// メモリ上に記録を足す（答え合わせ用。保存しない）。pairs は（入力文, アプリのキー）
    public func addExamples(_ pairs: [(String, String)]) {
        var grouped: [String: [ExampleNode.Link]] = [:]
        var order: [String] = []
        for (q, k) in pairs where !q.isEmpty && !k.isEmpty {
            if grouped[q] == nil { order.append(q) }
            grouped[q, default: []].append(.init(appKey: k))
        }
        lock.lock()
        examples += order.map { ExampleNode(q: $0, links: grouped[$0]!) }
        rebuildIndex()
        lock.unlock()
    }

    /// 選んで開いた組を覚える（Store に保存し、メモリにも足す）
    public func learn(query: String, app: AppEntry) {
        let q = query.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        store?.recordChoice(query: q, app: app)
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
        }
        rebuildIndex()
        lock.unlock()
    }

    /// lock を持った状態で呼ぶ
    private func rebuildIndex() {
        var c = AppIndex()
        c.setItems(names: apps.map { [$0.jp, $0.name, String(($0.path as NSString).lastPathComponent.dropLast(4))] },
                   dictTexts: apps.map { Describe.dictText($0, useDict: useDict) })
        for ex in examples {
            c.addExample(text: ex.q, links: ex.links.compactMap { l in byKey[l.appKey].map { ($0, l.weight) } })
        }
        index = c
    }

    public func search(_ query: String, limit: Int = 8, useExamples: Bool = true) -> [SearchResult] {
        searchJudged(query, limit: limit, useExamples: useExamples).results
    }

    /// search と同じ並びに「見つからない」の印を付けて返す（弾いても候補は消さない）
    public func searchJudged(_ query: String, limit: Int = 8, useExamples: Bool = true) -> Judged<SearchResult> {
        let q = query.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return Judged(results: [], noMatch: false, signals: MatchSignals()) }
        var m = appMix
        if !useExamples { m.useExamples = false }
        // 入力欄のコマンド（#type app #name …）。コマンドが無ければ今までどおり
        let f = QueryFilters.parse(query.precomposedStringWithCanonicalMapping)
        guard f.hasSyntax else { return rankAppsJudged(query: q, mix: m, limit: limit) }
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
        var j = rankAppsJudged(query: f.text, mix: m, limit: limit, allow: allow)
        j.filters = f
        return j
    }

    /// Raiden からファイルを開いたとき、実際に開いたアプリを覚え（file → app の opened_with の線）、
    /// 直前 30 分以内に Raiden から開いた物と co_used の線を張る（#with の加点）
    public func recordOpened(file path: String, isDir: Bool = false, appURL: URL?) {
        guard let store else { return }
        store.recordOpenedTogether(path: path, isDir: isDir)
        guard !isDir, let app = appURL ?? NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path)) else { return }
        let key = Bundle(url: app)?.bundleIdentifier ?? app.standardizedFileURL.path
        lock.lock()
        let name = byKey[key].map { apps[$0].jp } ?? app.deletingPathExtension().lastPathComponent
        lock.unlock()
        store.recordOpenedWith(file: path, appKey: key, appName: name)
    }

    public func rankAppsJudged(query q: String, mix: Mix, limit: Int = 8, allow: [Bool]? = nil, now: Date = Date()) -> Judged<SearchResult> {
        lock.lock()
        let c = index, apps = self.apps, top = topOpener
        lock.unlock()
        let ok = allow.flatMap { $0.count == apps.count ? $0 : nil }
        // いつも開くアプリ（入力の種類の言葉）と最近使ったアプリの加点
        let boost = openBonus > 0 ? Set(QueryIntent.parse(q).families.compactMap { top[$0] }) : []
        let t = Int(now.timeIntervalSince1970)
        let extra = apps.indices.map { i -> Float in
            var x: Float = boost.contains(i) ? openBonus : 0
            if recentBonus > 0 && apps[i].lastUsed > 0 { x += recentBonus * Float(exp(-Double(max(0, t - apps[i].lastUsed)) / 86400 / 30)) }
            return x
        }
        let ranked = Ranker.rank(c, query: q, mix: mix, extra: extra, names: apps.map(\.jp), limit: max(limit, 3), allow: ok)
        guard let first = ranked.first else { return Judged(results: [], noMatch: allow != nil, signals: MatchSignals()) }
        var s = MatchSignals()
        s.top1 = first.1.total
        s.top2 = ranked.count > 1 ? ranked[1].1.total : first.1.total - 1
        s.nameHit = first.1.name > 0; s.dictHit = first.1.dict > 0; s.exampleHit = first.1.example > 0
        return Judged(results: ranked.prefix(limit).map { SearchResult(app: apps[$0.0], score: $0.1.total) },
                      noMatch: !first.1.hit, signals: s)
    }

    // MARK: - ファイル・フォルダ（Spotlight）

    /// 「入力 → ファイル」を選んだ記録を残す（次から、入力の文字が近ければ加点する）
    public func learnFile(query: String, file f: FileEntry) {
        let q = query.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        store?.recordFileChoice(query: q, path: f.path, isDir: f.isDir, name: f.name)
    }

    public func searchFiles(_ query: String, limit: Int = 8, now: Date = Date()) -> [FileResult] {
        searchFilesJudged(query, limit: limit, now: now).results
    }

    /// Spotlight に問い合わせて並べる。「見つからない」は結果が 0 件のとき。
    /// 前の問い合わせが走っていれば止めてから始める（SpotlightSearch.search）。打つたびの取り消しは cancelFiles
    public func searchFilesJudged(_ query: String, limit: Int = 8, now: Date = Date()) -> Judged<FileResult> {
        let q = query.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return Judged(results: [], noMatch: false, signals: MatchSignals()) }
        let f = QueryFilters.parse(q, now: now)
        if f.hasSyntax {
            var none = Judged<FileResult>(results: [], noMatch: false, signals: MatchSignals())
            none.filters = f
            guard f.allowsFiles, f.isActive || !f.text.isEmpty else { return none }
        }
        spotlight.cancel()
        let r = spotlight.search(q, filters: f.hasSyntax ? f : nil, limit: limit, now: now)
        var s = MatchSignals()
        s.fetched = r.fetched; s.ms = r.ms
        if let a = r.files.first { s.top1 = a.score; s.top2 = r.files.count > 1 ? r.files[1].score : a.score - 1 }
        var j = Judged(results: r.files, noMatch: !r.cancelled && r.files.isEmpty, signals: s)
        if f.hasSyntax { j.filters = f }
        return j
    }

    /// 走っているファイルの問い合わせを止める（次の文字が来たとき）
    public func cancelFiles() { spotlight.cancel() }
}

public enum RaidenPaths {
    public static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Raiden", isDirectory: true)
    }
}

/// いまのプロセスのメモリ（アクティビティモニタの「メモリ」と同じ phys_footprint）
public func physFootprintMB() -> Double { vmInfo().map { Double($0.phys_footprint) / 1_048_576 } ?? -1 }

/// 実メモリに載っているページ
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
