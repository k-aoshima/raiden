import Foundation
import SQLite3

/// ~/Library/Application Support/Raiden/raiden.sqlite（OS 標準の SQLite3 を直接使う）
///
/// ベクトルとグラフを一緒に使えるよう、点（nodes）と線（edges）の 2 表にしている。
///   nodes  id, kind（app / example / file / folder）, key（bundle id・入力文・パス）, name, description,
///          vector・desc_hash（前の版の名残。今は使わず空）, updated_at
///          file / folder は「選んだ」「Raiden から開いた」記録の相手としてだけ置く（一覧・ベクトルは持たない。検索は Spotlight）
///   edges  from_id, to_id, kind（example→app / file の chose、file→app の opened_with、Raiden から 30 分以内に続けて開いた物どうしの co_used）,
///          weight（選んだ回数など）, last_used
public final class Store {
    var db: OpaquePointer?
    let lock = NSLock()
    public let url: URL

    public static var defaultURL: URL { RaidenPaths.support.appendingPathComponent("raiden.sqlite") }

    public enum StoreError: Error { case open(String), sql(String) }

    public init(url: URL = Store.defaultURL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw StoreError.open(url.path) }
        try exec("""
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS nodes(
          id INTEGER PRIMARY KEY,
          kind TEXT NOT NULL,
          key TEXT NOT NULL,
          name TEXT,
          description TEXT,
          vector BLOB,
          desc_hash TEXT,
          updated_at INTEGER,
          UNIQUE(kind, key));
        CREATE TABLE IF NOT EXISTS edges(
          from_id INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
          to_id INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
          kind TEXT NOT NULL,
          weight REAL NOT NULL DEFAULT 1,
          last_used INTEGER,
          PRIMARY KEY(from_id, to_id, kind));
        CREATE INDEX IF NOT EXISTS edges_to ON edges(to_id, kind);
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
        """)
        try exec(Store.searchLogSchema)
        migratedFiles = dropFileIndex()
        // 前の起動の VACUUM や書き込みが -wal に残っていると本体が大きいままなので、起動のたびに書き戻す（変換済みの DB も）
        try? exec("PRAGMA wal_checkpoint(TRUNCATE)")
        compactIfBloated()
    }

    /// 空いたページが中身より多く 4MB を超えていたら VACUUM で詰めて、-wal も本体へ書き戻す。
    /// ベクトルの作り直し（モデルを替えた時など）で数十 MB の空きが残り、auto_vacuum が無いのでファイルが大きいままになるため。
    /// 中身は 1,000 件で 1MB ほどなので、VACUUM は数十 ms。詰めたらそのページ数を返す（詰めなければ 0）
    @discardableResult
    public func compactIfBloated() -> Int {
        lock.lock(); defer { lock.unlock() }
        func int(_ sql: String) -> Int {
            guard let st = prepare(sql) else { return 0 }
            defer { sqlite3_finalize(st) }
            return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
        }
        let pages = int("PRAGMA page_count"), free = int("PRAGMA freelist_count"), size = int("PRAGMA page_size")
        guard free * size > 4 << 20, free > pages - free else { return 0 }
        try? exec("VACUUM")
        try? exec("PRAGMA wal_checkpoint(TRUNCATE)")
        return free
    }

    /// 起動時に消した前の版のファイル・フォルダの点の数（0 なら済み・新しい DB。dropFileIndex）
    public private(set) var migratedFiles = 0

    deinit { sqlite3_close(db) }

    // MARK: - 小道具

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw StoreError.sql(m)
        }
    }

    static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func prepare(_ sql: String) -> OpaquePointer? {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        return st
    }

    func bind(_ st: OpaquePointer?, _ i: Int32, _ s: String) {
        sqlite3_bind_text(st, i, s, -1, Store.TRANSIENT)
    }

    func text(_ st: OpaquePointer?, _ i: Int32) -> String {
        sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
    }

    var now: Int64 { Int64(Date().timeIntervalSince1970) }

    static func hash(_ s: String) -> String {
        // FNV-1a 64bit（変更検知用。暗号用途ではない）
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// 点を足すか更新して id を返す
    func upsertNode(kind: String, key: String, name: String, description: String) -> Int64 {
        let sql = "INSERT INTO nodes(kind,key,name,description,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(kind,key) DO UPDATE SET name=excluded.name, updated_at=excluded.updated_at RETURNING id"
        guard let st = prepare(sql) else { return -1 }
        defer { sqlite3_finalize(st) }
        bind(st, 1, kind); bind(st, 2, key); bind(st, 3, name); bind(st, 4, description)
        sqlite3_bind_int64(st, 5, now)
        return sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int64(st, 0) : -1
    }

    // MARK: - 例の点と chose の線

    /// 例の点を、chose の線でつながったアプリと一緒に全部読む（ベクトルは使わない。入力の文字の一致で引く）
    public func examples() -> [ExampleNode] {
        lock.lock(); defer { lock.unlock() }
        var nodes: [(Int64, String)] = []
        if let st = prepare("SELECT id, key FROM nodes WHERE kind='example'") {
            while sqlite3_step(st) == SQLITE_ROW { nodes.append((sqlite3_column_int64(st, 0), text(st, 1))) }
            sqlite3_finalize(st)
        }
        var links: [Int64: [ExampleNode.Link]] = [:]
        if let st = prepare("""
            SELECT e.from_id, a.key, e.weight, e.last_used FROM edges e JOIN nodes a ON a.id = e.to_id
            WHERE e.kind='chose' AND a.kind='app'
            """) {
            while sqlite3_step(st) == SQLITE_ROW {
                links[sqlite3_column_int64(st, 0), default: []].append(.init(
                    appKey: text(st, 1), weight: Float(sqlite3_column_double(st, 2)),
                    lastUsed: Int(sqlite3_column_int64(st, 3))))
            }
            sqlite3_finalize(st)
        }
        return nodes.compactMap { id, q in links[id].flatMap { $0.isEmpty ? nil : ExampleNode(q: q, links: $0) } }
    }

    /// 「入力文 q でアプリ app を選んだ」を記録する。例の点を足し、chose の線の重み（回数）を 1 増やす。
    public func recordChoice(query q: String, app: AppEntry) {
        lock.lock(); defer { lock.unlock() }
        try? exec("BEGIN")
        let ex = upsertNode(kind: "example", key: q, name: q, description: q)
        let ap = upsertNode(kind: "app", key: app.key, name: app.jp, description: app.jp)
        if ex >= 0, ap >= 0, let st = prepare("""
            INSERT INTO edges(from_id, to_id, kind, weight, last_used) VALUES(?,?,'chose',1,?)
            ON CONFLICT(from_id, to_id, kind) DO UPDATE SET weight = weight + 1, last_used = excluded.last_used
            """) {
            sqlite3_bind_int64(st, 1, ex); sqlite3_bind_int64(st, 2, ap); sqlite3_bind_int64(st, 3, now)
            sqlite3_step(st)
            sqlite3_finalize(st)
        }
        try? exec("COMMIT")
    }

    /// 「入力文 q でファイル・フォルダ path を選んだ」を記録する。例の点を足し、例 → ファイルの chose の線の重みを 1 増やす。
    /// ファイルの点はベクトル無しで作る。例の点のベクトルは作らない（ファイルの例は文字の一致で引く。同じ言い方でアプリも選べば
    /// recordChoice がベクトルを入れる）
    public func recordFileChoice(query q: String, path: String, isDir: Bool, name: String) {
        lock.lock(); defer { lock.unlock() }
        try? exec("BEGIN")
        let ex = upsertNode(kind: "example", key: q, name: q, description: q)
        let fid = upsertNode(kind: isDir ? "folder" : "file", key: path, name: name, description: "")
        if ex >= 0, fid >= 0, let st = prepare("""
            INSERT INTO edges(from_id, to_id, kind, weight, last_used) VALUES(?,?,'chose',1,?)
            ON CONFLICT(from_id, to_id, kind) DO UPDATE SET weight = weight + 1, last_used = excluded.last_used
            """) {
            sqlite3_bind_int64(st, 1, ex); sqlite3_bind_int64(st, 2, fid); sqlite3_bind_int64(st, 3, now)
            sqlite3_step(st)
            sqlite3_finalize(st)
        }
        try? exec("COMMIT")
    }

    /// ファイル・フォルダを選んだ例を（入力文, パス, 回数）で全部読む（SpotlightSearch.examples）
    public func fileExamples() -> [(String, String, Float)] {
        lock.lock(); defer { lock.unlock() }
        guard let st = prepare("""
            SELECT x.key, f.key, e.weight FROM edges e JOIN nodes x ON x.id = e.from_id JOIN nodes f ON f.id = e.to_id
            WHERE e.kind='chose' AND x.kind='example' AND f.kind IN ('file','folder')
            ORDER BY e.last_used
            """) else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [(String, String, Float)] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append((text(st, 0), text(st, 1), Float(sqlite3_column_double(st, 2)))) }
        return out
    }

    func columns(_ table: String) -> Set<String> {
        var out = Set<String>()
        guard let st = prepare("PRAGMA table_info(\(table))") else { return out }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW { out.insert(text(st, 1)) }
        return out
    }

    // MARK: - meta

    public func meta(_ k: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let st = prepare("SELECT v FROM meta WHERE k = ?") else { return nil }
        defer { sqlite3_finalize(st) }
        bind(st, 1, k)
        return sqlite3_step(st) == SQLITE_ROW ? text(st, 0) : nil
    }

    public func setMeta(_ k: String, _ v: String?) {
        lock.lock(); defer { lock.unlock() }
        guard let st = prepare(v == nil ? "DELETE FROM meta WHERE k = ?" : "INSERT OR REPLACE INTO meta(k, v) VALUES(?, ?)") else { return }
        defer { sqlite3_finalize(st) }
        bind(st, 1, k)
        if let v { bind(st, 2, v) }
        sqlite3_step(st)
    }

    // MARK: - アプリとファイルの線

    /// 前の版（自前のファイル一覧とベクトル）の名残を消す。起動時に一度だけ（meta の files が spotlight1 になったら何もしない）。
    /// ファイル・フォルダの点のうち「選んだ」「開いた」記録の相手でない物と、contains / co_used / co_time / opens の線を消し、
    /// どの点もベクトル・desc_hash を空に、ファイル・フォルダは一覧の中身（entry）も空にして、一覧の保存の印（file_scope など）を
    /// 消して VACUUM する。消したファイル・フォルダの点の数を返す
    @discardableResult
    public func dropFileIndex() -> Int {
        lock.lock(); defer { lock.unlock() }
        if let st = prepare("SELECT v FROM meta WHERE k='files'") {
            defer { sqlite3_finalize(st) }
            if sqlite3_step(st) == SQLITE_ROW, text(st, 0) == "spotlight1" { return 0 }
        }
        func int(_ sql: String) -> Int {
            guard let st = prepare(sql) else { return 0 }
            defer { sqlite3_finalize(st) }
            return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
        }
        let before = int("SELECT COUNT(*) FROM nodes WHERE kind IN ('file','folder')")
        try? exec("BEGIN")
        try? exec("DELETE FROM edges WHERE kind IN ('contains','co_used','co_time','opens')")
        try? exec("""
            DELETE FROM nodes WHERE kind IN ('file','folder') AND id NOT IN
              (SELECT to_id FROM edges WHERE kind='chose' UNION SELECT from_id FROM edges WHERE kind='opened_with')
            """)
        let hasEntry = columns("nodes").contains("entry")
        try? exec("UPDATE nodes SET description=''\(hasEntry ? ", entry=NULL" : "") WHERE kind IN ('file','folder')")
        try? exec("UPDATE nodes SET vector=NULL, desc_hash=NULL")
        try? exec("DELETE FROM meta WHERE k IN ('file_scope','fs_event_id','fs_uuid','file_vectors')")
        try? exec("INSERT OR REPLACE INTO meta(k, v) VALUES('files', 'spotlight1')")
        try? exec("COMMIT")
        let after = int("SELECT COUNT(*) FROM nodes WHERE kind IN ('file','folder')")
        try? exec("VACUUM")
        try? exec("PRAGMA wal_checkpoint(TRUNCATE)")
        return before - after
    }

    /// Raiden から開いた記録の続き: path を開いた時刻を残し（opened_with の線の last_used）、直前 window 秒以内に Raiden から開いた
    /// ほかのファイル・フォルダと co_used の線を張る（両向き、重みに 1 足す）。#with の加点に使う
    public func recordOpenedTogether(path: String, isDir: Bool, window: Int = SpotlightSearch.withWindow) {
        lock.lock(); defer { lock.unlock() }
        try? exec("BEGIN")
        let me = upsertNode(kind: isDir ? "folder" : "file", key: path, name: (path as NSString).lastPathComponent,
                            description: "")
        var others: [Int64] = []
        if me >= 0, let st = prepare("""
            SELECT DISTINCT e.from_id FROM edges e JOIN nodes f ON f.id = e.from_id
            WHERE e.kind IN ('opened_with','opened') AND f.kind IN ('file','folder') AND e.last_used >= ? AND e.from_id != ?
            """) {
            sqlite3_bind_int64(st, 1, now - Int64(window)); sqlite3_bind_int64(st, 2, me)
            while sqlite3_step(st) == SQLITE_ROW { others.append(sqlite3_column_int64(st, 0)) }
            sqlite3_finalize(st)
        }
        if let st = prepare("""
            INSERT INTO edges(from_id, to_id, kind, weight, last_used) VALUES(?,?,'co_used',1,?)
            ON CONFLICT(from_id, to_id, kind) DO UPDATE SET weight = weight + 1, last_used = excluded.last_used
            """) {
            for o in others {
                for (a, b) in [(me, o), (o, me)] {
                    sqlite3_reset(st)
                    sqlite3_bind_int64(st, 1, a); sqlite3_bind_int64(st, 2, b); sqlite3_bind_int64(st, 3, now)
                    sqlite3_step(st)
                }
            }
            sqlite3_finalize(st)
        }
        // 開いた時刻（開くアプリが分からなかった物も残すよう、自分への 'opened' の線に時刻を置く）
        if me >= 0, let st = prepare("""
            INSERT INTO edges(from_id, to_id, kind, weight, last_used) VALUES(?,?,'opened',1,?)
            ON CONFLICT(from_id, to_id, kind) DO UPDATE SET weight = weight + 1, last_used = excluded.last_used
            """) {
            sqlite3_bind_int64(st, 1, me); sqlite3_bind_int64(st, 2, me); sqlite3_bind_int64(st, 3, now)
            sqlite3_step(st)
            sqlite3_finalize(st)
        }
        try? exec("COMMIT")
    }

    /// path と co_used の線でつながったファイル・フォルダ（パス → 重み）
    public func coUsed(_ path: String) -> [String: Float] {
        lock.lock(); defer { lock.unlock() }
        guard let st = prepare("""
            SELECT t.key, e.weight FROM edges e JOIN nodes f ON f.id = e.from_id JOIN nodes t ON t.id = e.to_id
            WHERE e.kind='co_used' AND f.kind IN ('file','folder') AND f.key = ?
            """) else { return [:] }
        defer { sqlite3_finalize(st) }
        bind(st, 1, path)
        var out: [String: Float] = [:]
        while sqlite3_step(st) == SQLITE_ROW { out[text(st, 0)] = Float(sqlite3_column_double(st, 1)) }
        return out
    }

    /// Raiden から開いたファイルと、実際に開いたアプリ（file → app の opened_with。重みは回数）
    public func recordOpenedWith(file path: String, appKey: String, appName: String) {
        lock.lock(); defer { lock.unlock() }
        try? exec("BEGIN")
        let f = upsertNode(kind: "file", key: path, name: (path as NSString).lastPathComponent,
                           description: "")
        let a = upsertNode(kind: "app", key: appKey, name: appName, description: appName)
        if f >= 0, a >= 0, let st = prepare("""
            INSERT INTO edges(from_id, to_id, kind, weight, last_used) VALUES(?,?,'opened_with',1,?)
            ON CONFLICT(from_id, to_id, kind) DO UPDATE SET weight = weight + 1, last_used = excluded.last_used
            """) {
            sqlite3_bind_int64(st, 1, f); sqlite3_bind_int64(st, 2, a); sqlite3_bind_int64(st, 3, now)
            sqlite3_step(st)
            sqlite3_finalize(st)
        }
        try? exec("COMMIT")
    }

    public func edgeCount(kind: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let st = prepare("SELECT COUNT(*) FROM edges WHERE kind=?") else { return 0 }
        defer { sqlite3_finalize(st) }
        bind(st, 1, kind)
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int(st, 0)) : 0
    }

    public func count(kind: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let st = prepare("SELECT COUNT(*) FROM nodes WHERE kind=?") else { return 0 }
        defer { sqlite3_finalize(st) }
        bind(st, 1, kind)
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int(st, 0)) : 0
    }
}
