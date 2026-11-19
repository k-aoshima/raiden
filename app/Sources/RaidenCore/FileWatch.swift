import CoreServices
import Foundation

/// FSEvents でフォルダの変化を見張る。短い間にまとめて来た変化（解凍・コピー・git 操作）は、
/// 静かになって quiet 秒（ただし最初の変化から最大 maxWait 秒）たってから 1 回にまとめて渡す。
public final class FSWatcher {
    public struct Change: Sendable {
        public var paths: Set<String> = []      // 変化した物（NFC）
        public var rescan: Set<String> = []     // 履歴が途切れたので中を全部見直す場所
        public var isEmpty: Bool { paths.isEmpty && rescan.isEmpty }
        public init(paths: Set<String> = [], rescan: Set<String> = []) { self.paths = paths; self.rescan = rescan }
    }

    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let quiet: TimeInterval, maxWait: TimeInterval
    private let onChange: (Change) -> Void
    private var pending = Change()
    private var firstAt: Date?
    private var flushItem: DispatchWorkItem?

    /// fileEvents: true なら 1 ファイルずつ、false ならフォルダ単位（アプリの場所はこれで足りる）
    public init?(paths: [String], fileEvents: Bool = true, latency: TimeInterval = 0.2,
                 quiet: TimeInterval = 0.6, maxWait: TimeInterval = 2.0, onChange: @escaping (Change) -> Void) {
        let watch = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !watch.isEmpty else { return nil }
        self.queue = DispatchQueue(label: "raiden.fsevents", qos: .utility)
        self.quiet = quiet; self.maxWait = maxWait; self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        var flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        if fileEvents { flags |= UInt32(kFSEventStreamCreateFlagFileEvents) }
        let cb: FSEventStreamCallback = { _, info, n, rawPaths, rawFlags, _ in
            guard let info else { return }
            let me = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
            var ev: [(String, FSEventStreamEventFlags)] = []
            for i in 0..<min(n, paths.count) { ev.append((paths[i], rawFlags[i])) }
            me.receive(ev)
        }
        guard let s = FSEventStreamCreate(nil, cb, &ctx, watch as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          latency, FSEventStreamCreateFlags(flags)) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    deinit { stop() }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    static let mustScan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                                  | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)

    /// queue の上で呼ばれる
    private func receive(_ ev: [(String, FSEventStreamEventFlags)]) {
        for (p, f) in ev {
            let path = p.hasSuffix("/") && p.count > 1 ? String(p.dropLast()) : p
            let n = path.precomposedStringWithCanonicalMapping
            if f & Self.mustScan != 0 { pending.rescan.insert(n) } else { pending.paths.insert(n) }
        }
        if firstAt == nil { firstAt = Date() }
        flushItem?.cancel()
        let wait = max(0, min(quiet, maxWait - Date().timeIntervalSince(firstAt!)))
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        flushItem = item
        queue.asyncAfter(deadline: .now() + wait, execute: item)
    }

    private func flush() {
        let c = pending
        pending = Change(); firstAt = nil; flushItem = nil
        if !c.isEmpty { onChange(c) }
    }
}

/// ファイル・フォルダの一覧を持ち、変化した物だけ作り直して Engine に入れる。
/// 同じ列（シリアルキュー）からだけ呼ぶこと。
public final class FileIndex {
    public let engine: Engine
    /// 検索の対象範囲。変えるときは setScope（同じ列から）
    private(set) public var scope: ScanScope
    public var roots: [String] { scope.roots }
    private(set) public var entries: [String: FileEntry] = [:]

    public struct Stats: Sendable {
        public var changed = 0, removed = 0, embedded = 0, examples = 0
        public var seconds: Double = 0
        /// FSEvents の履歴が途切れて中を見直した場所（全体を見直したときは roots）
        public var rescanned: [String] = []
    }

    public init(engine: Engine, scope: ScanScope = .default) {
        self.engine = engine
        self.scope = scope
    }

    /// 対象範囲を差し替える。外れた物はすぐ一覧から外し、増えた場所だけ拾い直してから Engine に入れ直す。
    /// 説明文が変わった（＝新しく入った）物だけベクトル化され、外れた物の点と線（例の chose の線も）は Store から消える。
    /// Engine は commit まで前の一覧のままなので、その間の検索は止まらない
    @discardableResult
    public func setScope(_ s: ScanScope, progress: ((Int, Int) -> Void)? = nil) -> Stats {
        let t0 = Date()
        let old = scope
        scope = s
        var st = Stats()
        if old.excludeNames != s.excludeNames || old.excludeDirs != s.excludeDirs {
            // 除外が変わったら、どこが増えるか分からないので全体を見直す（変わっていない物はベクトルを作り直さない）
            return fullScan(progress: progress)
        }
        let before = entries.count
        entries = entries.filter { FileCatalog.isIncluded($0.key, scope: s) }
        st.removed = before - entries.count
        let added = s.roots.filter { r in !old.roots.contains { r == $0 || r.hasPrefix($0 + "/") } }
        for e in FileCatalog.collect(roots: added, scope: s) where entries[e.path] == nil && FileCatalog.isIncluded(e.path, scope: s) {
            entries[e.path] = e; st.changed += 1
        }
        let s2 = commit(progress: progress)
        st.embedded = s2.embedded; st.examples = s2.examples
        st.seconds = Date().timeIntervalSince(t0)
        return st
    }

    /// 全体を見直す（起動時・1 日 1 回・履歴が途切れて場所が分からないとき）。変わった物だけベクトルを作り直す。
    /// progress は（作った数, 作る数）
    @discardableResult
    public func fullScan(progress: ((Int, Int) -> Void)? = nil) -> Stats {
        let t0 = Date()
        var es: [String: FileEntry] = [:]
        for e in FileCatalog.collect(scope: scope) { es[e.path] = e }
        entries = es
        var st = commit(progress: progress)
        st.changed = es.count
        st.seconds = Date().timeIntervalSince(t0)
        return st
    }

    /// FSEvents の変化を当てる。追加・変更・名前変更はその物を作り直し、消えた物は中の物ごと外す。
    /// 中の物が増減したフォルダは説明文（中身の名前と数）が変わるので、親も作り直す。
    @discardableResult
    public func apply(_ c: FSWatcher.Change) -> Stats {
        let t0 = Date()
        var st = Stats()
        // roots より上（"/" など）で履歴が途切れたら全体を見直す
        if c.rescan.contains(where: { r in roots.contains { $0 == r || $0.hasPrefix(r + "/") } }) {
            var full = fullScan()
            full.rescanned = Array(c.rescan)
            return full
        }
        st.rescanned = Array(c.rescan)
        var touched = Set<String>()
        for r in c.rescan {
            removeTree(r, keepSelf: true, &st)
            for e in FileCatalog.collect(roots: [r], scope: scope) where FileCatalog.isIncluded(e.path, scope: scope) {
                entries[e.path] = e; st.changed += 1
            }
            touched.insert(r)
        }
        for p in c.paths { touched.insert(p) }
        var parents = Set<String>()
        for p in touched {
            parents.insert((p as NSString).deletingLastPathComponent)
            guard FileCatalog.isIncluded(p, scope: scope) else { continue }
            if let e = FileCatalog.entry(path: p) {
                let isNew = entries[p] == nil
                entries[p] = e; st.changed += 1
                // 入ってきたフォルダ（移動・解凍）は中も拾う
                if e.isDir && isNew {
                    for x in FileCatalog.collect(roots: [p], scope: scope) where FileCatalog.isIncluded(x.path, scope: scope) {
                        entries[x.path] = x; st.changed += 1
                    }
                }
            } else {
                removeTree(p, keepSelf: false, &st)
            }
        }
        for p in parents.subtracting(touched) where entries[p] != nil {
            if let e = FileCatalog.entry(path: p) { entries[p] = e } else { removeTree(p, keepSelf: false, &st) }
        }
        let s2 = commit(progress: nil)
        st.embedded = s2.embedded; st.examples = s2.examples
        st.seconds = Date().timeIntervalSince(t0)
        return st
    }

    private func removeTree(_ p: String, keepSelf: Bool, _ st: inout Stats) {
        if !keepSelf, entries.removeValue(forKey: p) != nil { st.removed += 1 }
        let pre = p + "/"
        for k in entries.keys where k.hasPrefix(pre) { entries.removeValue(forKey: k); st.removed += 1 }
    }

    /// Engine に入れ直す。一覧はすぐ入れ替わり（ベクトルの無い物も名前の一致と絞り込みでは出る）、
    /// ベクトル化の残りは大事な物から順に列に積む。background でなければ（答え合わせ・確かめ）、ここで全部作る。
    /// background でも残りが少なければ（FSEvents の数件の変化）ここで作る。
    /// setFiles で Corpus が作り直されて例が消えるので、保存済みの「入力 → ファイル」の例を入れ直す
    private func commit(progress: ((Int, Int) -> Void)?) -> Stats {
        var st = Stats()
        let list = entries.values.sorted { $0.path < $1.path }
        let p = engine.installFiles(list)
        shortQueue = prioritized(p.short)
        fullQueue = prioritized(p.full)
        shortTotal = shortQueue.count; shortDone = 0
        fullTotal = fullQueue.count; fullDone = 0
        if !background || shortQueue.count + fullQueue.count <= Self.inlineLimit {
            st.embedded = embedAll(progress: progress)
        } else {
            st.embedded = 0
            if shortTotal > 0 { progress?(0, shortTotal) }
        }
        let exs = engine.store?.fileExamples() ?? []
        if !exs.isEmpty { engine.addFileExamples(exs) }
        st.examples = exs.count
        return st
    }

    /// true なら commit でベクトルを作らず、embedStep で少しずつ進める（アプリ）
    public var background = false
    /// background でもその場で作る残りの数（FSEvents の数件の変化はすぐ検索に出したい）
    static let inlineLimit = 64
    private var shortQueue: [String] = [], fullQueue: [String] = []
    /// 短い説明でまだベクトルの無い物の進み具合（設定窓の「ベクトルを作成中 d/t」）
    public private(set) var shortDone = 0, shortTotal = 0
    /// 中身の頭を入れた説明文での作り直しの進み具合
    public private(set) var fullDone = 0, fullTotal = 0
    public var hasPending: Bool { !shortQueue.isEmpty || !fullQueue.isEmpty }

    /// 残りを全部作る。作った数を返す
    @discardableResult
    public func embedAll(progress: ((Int, Int) -> Void)? = nil) -> Int {
        let total = shortQueue.count + fullQueue.count
        if total > 0 { progress?(0, total) }
        var made = 0
        while hasPending {
            made += embedStep()
            progress?(shortDone + fullDone, total)
        }
        return made
    }

    /// 残りを 1 回分（count 件）作る。まだベクトルの無い物（短い説明）が先、中身を入れた作り直しは後。作った数を返す
    @discardableResult
    public func embedStep(count: Int = 64) -> Int {
        if !shortQueue.isEmpty {
            let part = Array(shortQueue.prefix(count))
            shortQueue.removeFirst(part.count)
            shortDone += part.count
            return engine.embedFiles(part, full: false)
        }
        if !fullQueue.isEmpty {
            let part = Array(fullQueue.prefix(count))
            fullQueue.removeFirst(part.count)
            fullDone += part.count
            return engine.embedFiles(part, full: true)
        }
        return 0
    }

    /// ベクトル化の順番: 最近使った・変えた物（30 日以内、新しい順）→ 検索の記録でよく選ぶ場所の中（回数の多い順）→ 残り（新しい順）
    func prioritized(_ paths: [String]) -> [String] {
        guard paths.count > 1 else { return paths }
        let chosen = engine.store?.chosenFolders() ?? [:]
        let now = Int(Date().timeIntervalSince1970)
        func key(_ p: String) -> (Int, Int, Int) {
            guard let e = entries[p] else { return (3, 0, 0) }
            let recent = max(e.lastUsed, e.mtime, e.added)
            if now - recent < 30 * 86400 { return (0, 0, -recent) }
            var dir = (p as NSString).deletingLastPathComponent, hits = 0
            for _ in 0..<12 {
                hits = max(hits, chosen[dir] ?? 0)
                if roots.contains(dir) || dir.count <= 1 { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
            return hits > 0 ? (1, -hits, -recent) : (2, 0, -recent)
        }
        let keys = Dictionary(paths.map { ($0, key($0)) }, uniquingKeysWith: { a, _ in a })
        return paths.sorted { keys[$0]! < keys[$1]! }
    }
}

/// 短い文（入力文・例）のベクトルを覚えておく Embedder。一覧を作り直すたびに例を入れ直すので、そのたびに作り直さないため。
/// 長い文（ファイルの説明文）は覚えない。
public final class CachedEmbedder: Embedder {
    public let base: Embedder
    private let lock = NSLock()
    private var cache: [String: [Float]] = [:]
    private let maxLength: Int, capacity: Int
    public var identifier: String { base.identifier }
    public var dimension: Int { base.dimension }

    public init(_ base: Embedder, maxLength: Int = 80, capacity: Int = 4096) {
        self.base = base; self.maxLength = maxLength; self.capacity = capacity
    }

    /// 長い文（ファイルの説明文）用。覚えずにそのまま渡す
    public func embedBatch(_ texts: [String], batch: Int) -> [[Float]] { base.embedBatch(texts, batch: batch) }

    public func embed(_ text: String) -> [Float] {
        guard text.count <= maxLength else { return base.embed(text) }
        lock.lock()
        if let v = cache[text] { lock.unlock(); return v }
        lock.unlock()
        let v = base.embed(text)
        // モデルを解放していて作れなかったとき（全部 0）は覚えない
        guard v.contains(where: { $0 != 0 }) else { return v }
        lock.lock()
        if cache.count >= capacity { cache.removeAll(keepingCapacity: true) }
        cache[text] = v
        lock.unlock()
        return v
    }
}
