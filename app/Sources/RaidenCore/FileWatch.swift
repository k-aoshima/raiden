import CoreServices
import Foundation

/// FSEvents でフォルダの変化を見張る。短い間にまとめて来た変化（解凍・コピー・git 操作）は、
/// 静かになって quiet 秒（ただし最初の変化から最大 maxWait 秒）たってから 1 回にまとめて渡す。
public final class FSWatcher {
    public struct Change: Sendable {
        public var paths: Set<String> = []      // 変化した物（NFC）
        public var rescan: Set<String> = []     // 履歴が途切れたので中を全部見直す場所
        /// この中で一番新しいイベントの ID（0 は無し）。処理し終えたら保存し、次の起動でここから受け取る
        public var lastId: UInt64 = 0
        /// 起動前の分（sinceWhen から今まで）を受け取り終えた印が入っていた
        public var historyDone = false
        public var isEmpty: Bool { paths.isEmpty && rescan.isEmpty }
        public init(paths: Set<String> = [], rescan: Set<String> = []) { self.paths = paths; self.rescan = rescan }
    }

    /// いまのイベント ID（ここから見張り始めるとき、これを保存しておけば次の起動で続きを受け取れる）
    public static var currentEventId: UInt64 { UInt64(FSEventsGetCurrentEventId()) }

    /// paths の載っているボリュームの FSEvents の UUID（並べてつないだ文字列）。変わっていたら保存したイベント ID は使えない
    public static func volumeUUIDs(_ paths: [String]) -> String {
        var out: [String] = []
        for p in paths {
            var st = stat()
            guard stat(p, &st) == 0, let u = FSEventsCopyUUIDForDevice(st.st_dev) else { out.append("?"); continue }
            let s = CFUUIDCreateString(nil, u) as String? ?? "?"
            if !out.contains(s) { out.append(s) }
        }
        return out.joined(separator: ",")
    }

    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let quiet: TimeInterval, maxWait: TimeInterval
    private let onChange: (Change) -> Void
    private var pending = Change()
    private var firstAt: Date?
    private var flushItem: DispatchWorkItem?

    /// fileEvents: true なら 1 ファイルずつ、false ならフォルダ単位（アプリの場所はこれで足りる）
    /// since: このイベント ID より後の変化から受け取る（止まっていた間の分も届く）。nil なら今から
    public init?(paths: [String], since: UInt64? = nil, fileEvents: Bool = true, latency: TimeInterval = 0.2,
                 quiet: TimeInterval = 0.6, maxWait: TimeInterval = 2.0, onChange: @escaping (Change) -> Void) {
        let watch = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !watch.isEmpty else { return nil }
        self.queue = DispatchQueue(label: "raiden.fsevents", qos: .utility)
        self.quiet = quiet; self.maxWait = maxWait; self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        var flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        if fileEvents { flags |= UInt32(kFSEventStreamCreateFlagFileEvents) }
        let cb: FSEventStreamCallback = { _, info, n, rawPaths, rawFlags, ids in
            guard let info else { return }
            let me = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
            var ev: [(String, FSEventStreamEventFlags, UInt64)] = []
            for i in 0..<min(n, paths.count) { ev.append((paths[i], rawFlags[i], UInt64(ids[i]))) }
            me.receive(ev)
        }
        let start = since.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, watch as CFArray, start,
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
    private func receive(_ ev: [(String, FSEventStreamEventFlags, UInt64)]) {
        for (p, f, id) in ev {
            pending.lastId = max(pending.lastId, id)
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { pending.historyDone = true; continue }
            // イベント ID が一周した: どこまで受け取ったか分からないので全体を見直す
            if f & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 { pending.rescan.insert("/"); continue }
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
        if !c.isEmpty || c.historyDone { onChange(c) }
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
        /// 差分で当てたか（false は全部入れ直した。changed も removed も 0 なら入れ直していない）
        public var incremental = false
        /// 全体の見直しが要る（background のとき。履歴が途切れた・範囲が増えた・除外が変わった）。呼んだ側が裏で
        /// beginScan → FileCatalog.collect → finishScan を行う（その間も今の一覧で検索できる）
        public var needsFullScan = false
    }

    // MARK: - 一覧の保存（起動のたびに OS に問い合わせ直さない）
    //
    // 一覧の中身は Store の nodes.entry に置き、起動時は loadSaved で読んで入れる。止まっていた間の変化は、保存した
    // FSEvents のイベント ID（meta の fs_event_id）から受け取って apply で当てる。範囲・除外が保存したときと違う、
    // ボリュームが替わった、履歴が途切れたときだけ全体を見直す。全体の見直しが終わるまで meta の file_scope は空にしておき、
    // 途中でアプリが終わっても次の起動で見直し直す

    /// 範囲と除外の印（保存した一覧がいまの設定のものか）
    public var scopeSignature: String {
        "v1\n" + scope.roots.joined(separator: "\u{1}") + "\n" + scope.excludeDirs.joined(separator: "\u{1}") + "\n"
            + scope.excludeNames.joined(separator: "\u{1}")
    }

    /// 保存した一覧を読んで入れる（範囲・除外が同じで、中身があるとき）。入れたら true
    @discardableResult
    public func loadSaved(progress: ((Int, Int) -> Void)? = nil) -> Bool {
        guard let store = engine.store, store.meta("file_scope") == scopeSignature else { return false }
        let list = store.loadFileEntries()
        guard !list.isEmpty else { return false }
        var es: [String: FileEntry] = [:]
        es.reserveCapacity(list.count)
        for e in list { es[e.path] = e }
        entries = es
        commit(progress: progress, persist: false)
        return true
    }

    /// 保存したイベント ID（ボリュームが同じとき）。これを FSWatcher の since に渡す
    public func savedEventId() -> UInt64? {
        guard let store = engine.store, let s = store.meta("fs_event_id"), let id = UInt64(s), id > 0,
              store.meta("fs_uuid") == FSWatcher.volumeUUIDs(roots) else { return nil }
        return id
    }

    private func saveEventId(_ id: UInt64) {
        guard id > 0, let store = engine.store else { return }
        if let s = store.meta("fs_event_id"), let old = UInt64(s), old >= id, store.meta("fs_uuid") == FSWatcher.volumeUUIDs(roots) { return }
        store.setMeta("fs_event_id", String(id))
        store.setMeta("fs_uuid", FSWatcher.volumeUUIDs(roots))
    }

    /// 保存した一覧をいまの設定のものと見なさない（全体の見直しが終わるまで）
    private func invalidateSaved() { engine.store?.setMeta("file_scope", "") }

    /// 全体の見直しの間（beginScan から finishScan まで）に来た変化。見直しの結果の上に当て直す
    private var scanBuffer: FSWatcher.Change?
    private var scanStartId: UInt64 = 0
    public var isScanning: Bool { scanBuffer != nil }

    /// 全体の見直しを始める（この後、別の列で FileCatalog.collect(scope:) を作り、できたら finishScan に渡す）
    public func beginScan() {
        if scanBuffer == nil { scanBuffer = FSWatcher.Change() }
        scanStartId = FSWatcher.currentEventId
        invalidateSaved()
    }

    /// 全体の見直しの結果を入れる。全部入れ直し（co_used / co_time の線と消した印もここで作り直す）、
    /// 見直しの間に来た変化を当て直し、一覧を保存する。scope は見直しを始めたときの物（途中で変わっていたら何もしない）
    @discardableResult
    public func finishScan(_ list: [FileEntry], scope s: ScanScope, progress: ((Int, Int) -> Void)? = nil) -> Stats {
        let t0 = Date()
        let buffered = scanBuffer ?? FSWatcher.Change()
        scanBuffer = nil
        guard s == scope else { return Stats() }
        var es: [String: FileEntry] = [:]
        es.reserveCapacity(list.count)
        for e in list { es[e.path] = e }
        entries = es
        var st = commit(progress: progress, persist: true)
        st.changed = es.count
        if !buffered.isEmpty {
            let b = apply(buffered)
            st.embedded += b.embedded
        }
        engine.store?.setMeta("file_scope", scopeSignature)
        saveEventId(scanStartId)
        st.seconds = Date().timeIntervalSince(t0)
        return st
    }

    /// 足した・変わった・消えた物がこれより多ければ、差分でなく全部入れ直す（解凍・git の大きな切り替えなど）。
    /// raiden-eval --bench-apply で決めた（README の FSEvents の節）。0 なら毎回全部入れ直す（前の作り）
    public var incrementalLimit = 5000
    /// 消した印がこの割合（点の数に対して）を超えたら、全部入れ直して詰める
    public var compactRatio = 0.1
    /// ただし印がこれより少なければ詰めない
    public var compactMin = 2000

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
            if background { invalidateSaved(); st.needsFullScan = true; return st }
            return fullScan(progress: progress)
        }
        let before = entries.count
        let gone = entries.keys.filter { !FileCatalog.isIncluded($0, scope: s) }
        for k in gone { entries[k] = nil }
        st.removed = before - entries.count
        let added = s.roots.filter { r in !old.roots.contains { r == $0 || r.hasPrefix($0 + "/") } }
        if background {
            // 外れた物はすぐ外す。増えた場所は裏の全体の見直しで拾う（数分かかることがあるので、この列を止めない）
            if !gone.isEmpty {
                if engine.fileSlotCount > 0 && gone.count <= incrementalLimit { _ = engine.patchFiles(upsert: [], remove: gone); st.incremental = true }
                else { commit(progress: nil, persist: false) }
            }
            if added.isEmpty { engine.store?.setMeta("file_scope", scopeSignature) } else { invalidateSaved(); st.needsFullScan = true }
            st.seconds = Date().timeIntervalSince(t0)
            return st
        }
        for e in FileCatalog.collect(roots: added, scope: s) where entries[e.path] == nil && FileCatalog.isIncluded(e.path, scope: s) {
            entries[e.path] = e; st.changed += 1
        }
        let s2 = commit(progress: progress)
        engine.store?.setMeta("file_scope", scopeSignature)
        st.embedded = s2.embedded; st.examples = s2.examples
        st.seconds = Date().timeIntervalSince(t0)
        return st
    }

    /// 全体を見直す（起動時・1 日 1 回・履歴が途切れて場所が分からないとき）。変わった物だけベクトルを作り直す。
    /// progress は（作った数, 作る数）
    @discardableResult
    public func fullScan(progress: ((Int, Int) -> Void)? = nil) -> Stats {
        let t0 = Date()
        beginScan()
        var st = finishScan(FileCatalog.collect(scope: scope), scope: scope, progress: progress)
        st.seconds = Date().timeIntervalSince(t0)
        return st
    }

    /// いまの一覧を全部入れ直す（消した印を詰める。読み直しはしない）
    @discardableResult
    public func rebuild(progress: ((Int, Int) -> Void)? = nil) -> Stats {
        let t0 = Date()
        var st = commit(progress: progress)
        st.changed = entries.count
        st.seconds = Date().timeIntervalSince(t0)
        return st
    }

    /// FSEvents の変化を当てる。追加・変更・名前変更はその物を作り直し、消えた物は中の物ごと外す。
    /// 中の物が増減したフォルダは説明文（中身の名前と数）が変わるので、親も作り直す。
    /// 当て終えたら c.lastId を保存する（次の起動はその続きから受け取る）
    @discardableResult
    public func apply(_ c: FSWatcher.Change) -> Stats {
        let st = applyChange(c)
        if !st.needsFullScan { saveEventId(c.lastId) }
        return st
    }

    private func applyChange(_ c: FSWatcher.Change) -> Stats {
        let t0 = Date()
        var st = Stats()
        var upserted = Set<String>(), removed = Set<String>()
        // 全体の見直しの最中なら、結果の上に当て直すため覚えておく（今の一覧にもそのまま当てる）
        if scanBuffer != nil { scanBuffer!.paths.formUnion(c.paths); scanBuffer!.rescan.formUnion(c.rescan) }
        // roots より上（"/" など）で履歴が途切れたら全体を見直す（background なら裏で。呼んだ側が beginScan から行う）
        if c.rescan.contains(where: { r in roots.contains { $0 == r || $0.hasPrefix(r + "/") } }) {
            if background {
                invalidateSaved()
                st.needsFullScan = true
                st.rescanned = Array(c.rescan)
                return st
            }
            var full = fullScan()
            full.rescanned = Array(c.rescan)
            return full
        }
        st.rescanned = Array(c.rescan)
        var touched = Set<String>()
        for r in c.rescan {
            removed.formUnion(removeTree(r, keepSelf: true, &st))
            for e in FileCatalog.collect(roots: [r], scope: scope) where FileCatalog.isIncluded(e.path, scope: scope) {
                entries[e.path] = e; st.changed += 1; upserted.insert(e.path)
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
                entries[p] = e; st.changed += 1; upserted.insert(p)
                // 入ってきたフォルダ（移動・解凍）は中も拾う
                if e.isDir && isNew {
                    for x in FileCatalog.collect(roots: [p], scope: scope) where FileCatalog.isIncluded(x.path, scope: scope) {
                        entries[x.path] = x; st.changed += 1; upserted.insert(x.path)
                    }
                }
            } else {
                removed.formUnion(removeTree(p, keepSelf: false, &st))
            }
        }
        for p in parents.subtracting(touched) where entries[p] != nil {
            if let e = FileCatalog.entry(path: p) { entries[p] = e; upserted.insert(p) } else { removed.formUnion(removeTree(p, keepSelf: false, &st)) }
        }
        // 範囲の中で増えた・変わった・消えた物が無ければ入れ直さない。入れ直しは全件を並べ直すので、~/Project のように
        // 16 万件あると 1 回 30 秒かかり、除外した場所（.git・build など）への書き込みのたびに走ってベクトル化が進まなかった
        if st.changed == 0 && st.removed == 0 {
            st.seconds = Date().timeIntervalSince(t0)
            return st
        }
        removed.subtract(upserted)
        let n = engine.fileSlotCount
        // 数件〜数千件の変化は差分で当てる（全部入れ直すと ~/Project 16 万件で 1 回 30 秒かかり、その間ベクトル化が止まる）
        if n > 0 && upserted.count + removed.count <= incrementalLimit {
            let list = upserted.compactMap { entries[$0] }.sorted { $0.path < $1.path }
            let p = engine.patchFiles(upsert: list, remove: Array(removed))
            engine.store?.saveFileEntries(list)
            let dead = engine.fileDeadCount
            if dead >= compactMin && Double(dead) > compactRatio * Double(engine.fileSlotCount) {
                // 消した印がたまったので詰める
                let s2 = commit(progress: nil)
                st.embedded = s2.embedded; st.examples = s2.examples
            } else {
                st.embedded = enqueue(p)
                st.incremental = true
            }
            st.seconds = Date().timeIntervalSince(t0)
            return st
        }
        let s2 = commit(progress: nil)
        st.embedded = s2.embedded; st.examples = s2.examples
        st.seconds = Date().timeIntervalSince(t0)
        return st
    }

    /// 差分で出たベクトル化の残りを列の先頭に足す（今の列は並べ直さない。変わったばかりの物はどうせ一番先）。
    /// 少なければ（inlineLimit 以下）その場で作る。作った数を返す
    private func enqueue(_ p: Engine.FilePending) -> Int {
        guard !p.isEmpty else { return 0 }
        let short = prioritized(p.short), full = prioritized(p.full)
        let s = Set(short), f = Set(full)
        if !s.isEmpty { let before = shortQueue.count; shortQueue.removeAll { s.contains($0) }; shortTotal -= before - shortQueue.count }
        if !f.isEmpty { let before = fullQueue.count; fullQueue.removeAll { f.contains($0) }; fullTotal -= before - fullQueue.count }
        if !background || short.count + full.count <= Self.inlineLimit {
            // その場で作る（列には入れない）
            var made = 0
            var i = 0
            while i < short.count { let part = Array(short[i..<min(i + 64, short.count)]); i += part.count; made += engine.embedFiles(part, full: false) }
            i = 0
            while i < full.count { let part = Array(full[i..<min(i + 64, full.count)]); i += part.count; made += engine.embedFiles(part, full: true) }
            if !background { embedAll() }
            return Set(short).union(full).count
        }
        shortQueue.insert(contentsOf: short, at: 0); shortTotal += short.count
        fullQueue.insert(contentsOf: full, at: 0); fullTotal += full.count
        return 0
    }

    /// 消えた物と（フォルダなら）中の物を一覧から外し、外したパスを返す。中を探すのはフォルダのときと keepSelf のときだけ
    /// （ファイル 1 件の削除で 16 万件を総なめしない）
    @discardableResult
    private func removeTree(_ p: String, keepSelf: Bool, _ st: inout Stats) -> [String] {
        var out: [String] = []
        let wasDir = entries[p]?.isDir ?? false
        if !keepSelf, entries.removeValue(forKey: p) != nil { st.removed += 1; out.append(p) }
        guard keepSelf || wasDir else { return out }
        let pre = p + "/"
        for k in entries.keys where k.hasPrefix(pre) { entries.removeValue(forKey: k); st.removed += 1; out.append(k) }
        return out
    }

    /// Engine に入れ直す。一覧はすぐ入れ替わり（ベクトルの無い物も名前の一致と絞り込みでは出る）、
    /// ベクトル化の残りは大事な物から順に列に積む。background でなければ（答え合わせ・確かめ）、ここで全部作る。
    /// background でも残りが少なければ（FSEvents の数件の変化）ここで作る。
    /// setFiles で Corpus が作り直されて例が消えるので、保存済みの「入力 → ファイル」の例を入れ直す
    /// persist: 一覧を Store に書く（中身が変わった行だけ書き換わる。保存した一覧から入れたときは書かない）
    @discardableResult
    private func commit(progress: ((Int, Int) -> Void)?, persist: Bool = true) -> Stats {
        var st = Stats()
        let list = entries.values.sorted { $0.path < $1.path }
        let p = engine.installFiles(list)
        if persist {
            let t = Date()
            engine.store?.saveFileEntries(list)
            lastSaveSeconds = Date().timeIntervalSince(t)
        }
        shortQueue = prioritized(p.short)
        fullQueue = prioritized(p.full)
        shortTotal = shortQueue.count; shortDone = 0
        fullTotal = fullQueue.count; fullDone = 0
        if !background || shortQueue.count + fullQueue.count <= Self.inlineLimit {
            embedAll(progress: progress)
            st.embedded = Set(p.short).union(p.full).count   // 短い説明と中身ありの 2 回作った物も 1 件と数える
        } else {
            st.embedded = 0
            if shortTotal > 0 { progress?(0, shortTotal) }
        }
        let exs = engine.store?.fileExamples() ?? []
        if !exs.isEmpty { engine.addFileExamples(exs) }
        st.examples = exs.count
        return st
    }

    /// 最後に一覧を全部保存した秒数
    public private(set) var lastSaveSeconds: Double = 0

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
        // 鍵は 1 回ずつ（複数のコアで）作って並べる。前は並べ替えの比べのたびに辞書を引き、16 万件で数秒かかった
        let keys = paths.parallelMap(minCount: 2048) { key($0) }
        return paths.indices.sorted { keys[$0] != keys[$1] ? keys[$0] < keys[$1] : $0 < $1 }.map { paths[$0] }
    }
}

/// 短い文（入力文・例）のベクトルを覚えておく Embedder。一覧を作り直すたびに例を入れ直すので、そのたびに作り直さないため。
/// 長い文（ファイルの説明文）は覚えない。
public final class CachedEmbedder: UrgentEmbedder {
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
    public func embedUrgent(_ texts: [String], batch: Int) -> [[Float]] {
        (base as? UrgentEmbedder)?.embedUrgent(texts, batch: batch) ?? base.embedBatch(texts, batch: batch)
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
