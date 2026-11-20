import CoreServices
import Foundation

/// FSEvents でフォルダの変化を見張る（アプリの場所。ファイル・フォルダは Spotlight に問い合わせるので見張らない）。短い間にまとめて来た変化（解凍・コピー・git 操作）は、
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
