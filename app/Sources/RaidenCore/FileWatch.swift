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
    public let roots: [String]
    private(set) public var entries: [String: FileEntry] = [:]

    public struct Stats: Sendable {
        public var changed = 0, removed = 0, embedded = 0, examples = 0
        public var seconds: Double = 0
    }

    public init(engine: Engine, roots: [String] = FileCatalog.defaultRoots) {
        self.engine = engine
        self.roots = roots
    }

    /// 全体を見直す（起動時・1 日 1 回・履歴が途切れて場所が分からないとき）。変わった物だけベクトルを作り直す
    @discardableResult
    public func fullScan(progress: ((Int) -> Void)? = nil) -> Stats {
        let t0 = Date()
        var es: [String: FileEntry] = [:]
        for e in FileCatalog.collect(roots: roots) { es[e.path] = e }
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
            return fullScan()
        }
        var touched = Set<String>()
        for r in c.rescan {
            removeTree(r, keepSelf: true, &st)
            for e in FileCatalog.collect(roots: [r]) where FileCatalog.isIncluded(e.path, roots: roots) {
                entries[e.path] = e; st.changed += 1
            }
            touched.insert(r)
        }
        for p in c.paths { touched.insert(p) }
        var parents = Set<String>()
        for p in touched {
            parents.insert((p as NSString).deletingLastPathComponent)
            guard FileCatalog.isIncluded(p, roots: roots) else { continue }
            if let e = FileCatalog.entry(path: p) {
                let isNew = entries[p] == nil
                entries[p] = e; st.changed += 1
                // 入ってきたフォルダ（移動・解凍）は中も拾う
                if e.isDir && isNew {
                    for x in FileCatalog.collect(roots: [p]) where FileCatalog.isIncluded(x.path, roots: roots) {
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

    /// Engine に入れ直す。説明文が変わった物だけベクトル化され、消えた物の点と線（例の chose の線も）は Store から消える。
    /// setFiles で Corpus が作り直されて例が消えるので、保存済みの「入力 → ファイル」の例を入れ直す
    private func commit(progress: ((Int) -> Void)?) -> Stats {
        var st = Stats()
        let list = entries.values.sorted { $0.path < $1.path }
        st.embedded = engine.setFiles(list, progress: progress)
        let exs = engine.store?.fileExamples() ?? []
        if !exs.isEmpty { engine.addFileExamples(exs) }
        st.examples = exs.count
        return st
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
