import Foundation

/// 動作の記録（起動・一覧の作り直し・ベクトル化の件数と時間・FSEvents の取りこぼしで見直した場所・エラー）。
/// ~/Library/Logs/Raiden/raiden.log に 1 行ずつ足す。maxBytes を超えたら raiden.1.log … raiden.<keep>.log に回し、
/// それより古いものと、keepDays 日より古い回したファイルは消す。手元だけに残し、外へは送らない。
/// NSLog にも同じ内容を出す（Console.app で見られるように）。
public final class RaidenLog: @unchecked Sendable {
    public static let shared = RaidenLog()

    public static var defaultDir: URL {
        if let d = ProcessInfo.processInfo.environment["RAIDEN_LOG_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Raiden", isDirectory: true)
    }

    public let dir: URL
    public let maxBytes: Int
    public let keep: Int
    public let keepDays: Int
    public var echo = true
    private let queue = DispatchQueue(label: "raiden.log", qos: .utility)
    private var handle: FileHandle?
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public init(dir: URL = RaidenLog.defaultDir, maxBytes: Int = 1_000_000, keep: Int = 5, keepDays: Int = 30) {
        self.dir = dir; self.maxBytes = maxBytes; self.keep = keep; self.keepDays = keepDays
    }

    public var fileURL: URL { dir.appendingPathComponent("raiden.log") }
    func rotated(_ i: Int) -> URL { dir.appendingPathComponent("raiden.\(i).log") }

    public func info(_ msg: String) { write("INFO", msg) }
    public func error(_ msg: String) { write("ERROR", msg) }

    public func write(_ level: String, _ msg: String) {
        if echo { NSLog("Raiden: %@", msg) }
        let line = "\(fmt.string(from: Date())) [\(level)] \(msg)\n"
        queue.async { self.append(line) }
    }

    /// 書き込みが終わるまで待つ（テストと終了時用）
    public func flush() { queue.sync {} }

    private func append(_ line: String) {
        let fm = FileManager.default
        if handle == nil {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: fileURL)
            _ = try? handle?.seekToEnd()
        }
        guard let h = handle else { return }
        try? h.write(contentsOf: Data(line.utf8))
        if let size = try? h.offset(), size > UInt64(maxBytes) { rotate() }
    }

    private func rotate() {
        let fm = FileManager.default
        try? handle?.close()
        handle = nil
        try? fm.removeItem(at: rotated(keep))
        if keep > 1 {
            for i in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: rotated(i).path) {
                try? fm.moveItem(at: rotated(i), to: rotated(i + 1))
            }
        }
        try? fm.moveItem(at: fileURL, to: rotated(1))
        pruneOld()
    }

    /// keepDays 日より古い回したファイルを消す（起動時にも呼ぶ）
    public func pruneOld(now: Date = Date()) {
        let fm = FileManager.default
        let cut = now.addingTimeInterval(-Double(keepDays) * 86400)
        for i in 1...max(1, keep + 5) {
            let u = rotated(i)
            guard let d = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date else { continue }
            if i > keep || d < cut { try? fm.removeItem(at: u) }
        }
    }
}

/// 動作の記録（RaidenLog.shared）に 1 行書く
public func rlog(_ msg: String) { RaidenLog.shared.info(msg) }
public func rlogError(_ msg: String) { RaidenLog.shared.error(msg) }
