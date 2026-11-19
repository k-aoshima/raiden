import Foundation

/// 並べ方の重み（raiden-eval の --sweep の結果で決めた。README 参照）
public struct RankParams: Sendable {
    public var knnK = 5               // k近傍法で見る過去の例の数
    public var knnWeight: Float = 1.0 // k近傍法の点数に掛ける重み
    public var knnMinSim: Float = 0.0 // これより遠い例は数えない
    public var prefixBonus: Float = 0.6   // 名前の先頭が一致
    public var substrBonus: Float = 0.35  // 名前の途中に含まれる
    public init() {}
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

/// 検索の本体。アプリも答え合わせ（raiden-eval）もこれを通す。
/// 近さはメモリに載せたベクトルとの総当たりの内積（数千件なら十分速い）。
public final class Engine {
    public let embedder: Embedder
    public var params = RankParams()
    public let useDict: Bool
    public let store: Store?
    private let lock = NSLock()
    private(set) public var apps: [AppEntry] = []
    private var appVecs: [[Float]] = []
    private var byKey: [String: Int] = [:]
    private(set) public var examples: [ExampleNode] = []
    private var exVecs: [[Float]] = []

    public init(embedder: Embedder, store: Store? = nil, useDict: Bool = true) {
        self.embedder = embedder
        self.store = store
        self.useDict = useDict
    }

    public func setApps(_ list: [AppEntry]) {
        let descs = list.map { Describe.text($0, useDict: useDict) }
        let vs: [[Float]]
        if let store {
            vs = store.appVectors(list, descriptions: descs, model: embedder.identifier) { embedder.embed($0) }
        } else {
            vs = descs.map { embedder.embed($0) }
        }
        lock.lock()
        apps = list; appVecs = vs
        byKey = Dictionary(list.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })
        lock.unlock()
    }

    /// 保存済みの例を読み込む（Store があるとき）
    public func loadExamples() {
        guard let store else { return }
        let rows = store.examples(model: embedder.identifier) { embedder.embed($0) }
        lock.lock()
        examples = rows.map(\.0); exVecs = rows.map(\.1)
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
        lock.unlock()
    }

    public func search(_ query: String, limit: Int = 8, useExamples: Bool = true) -> [SearchResult] {
        let q = query.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return [] }
        let v = embedder.embed(q)
        lock.lock()
        let apps = self.apps, appVecs = self.appVecs, byKey = self.byKey
        let examples = self.examples, exVecs = self.exVecs
        lock.unlock()
        var score = appVecs.map { Vec.dot($0, v) }
        if useExamples && !examples.isEmpty {
            let sims = exVecs.map { Vec.dot($0, v) }
            let order = sims.indices.sorted { sims[$0] > sims[$1] }.prefix(params.knnK)
            for (rank, i) in order.enumerated() {
                if sims[i] < params.knnMinSim { break }
                // example の点から chose の線をたどり、app の点に点数を配る（線の重みで按分）
                let links = examples[i].links
                let total = links.reduce(0) { $0 + $1.weight }
                for l in links {
                    guard let ai = byKey[l.appKey], total > 0 else { continue }
                    score[ai] += params.knnWeight * sims[i] / Float(rank + 1) * (l.weight / total)
                }
            }
        }
        for i in apps.indices {
            score[i] += Describe.nameBonus(q, apps[i], prefix: params.prefixBonus, substr: params.substrBonus)
        }
        let top = score.indices.sorted { score[$0] > score[$1] }.prefix(limit)
        return top.map { SearchResult(app: apps[$0], score: score[$0]) }
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
