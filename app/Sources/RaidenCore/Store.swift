import Foundation
import SQLite3

/// ~/Library/Application Support/Raiden/raiden.sqlite（OS 標準の SQLite3 を直接使う）
///
/// ベクトルとグラフを一緒に使えるよう、点（nodes）と線（edges）の 2 表にしている。
///   nodes  id, kind（app / example / file / folder）, key（bundle id・入力文・パス）, name, description,
///          vector（Float32 の BLOB）, desc_hash（モデル名＋説明文のハッシュ。変わった時だけ作り直す）, updated_at
///   edges  from_id, to_id, kind（example→app の chose、folder→中の物の contains、同じ日に使った物どうしの co_used）,
///          weight（選んだ回数など）, last_used
public final class Store {
    private var db: OpaquePointer?
    private let lock = NSLock()
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
    }

    deinit { sqlite3_close(db) }

    // MARK: - 小道具

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw StoreError.sql(m)
        }
    }

    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String) -> OpaquePointer? {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        return st
    }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ s: String) {
        sqlite3_bind_text(st, i, s, -1, Store.TRANSIENT)
    }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ v: [Float]) {
        _ = v.withUnsafeBytes { sqlite3_bind_blob(st, i, $0.baseAddress, Int32($0.count), Store.TRANSIENT) }
    }

    private func text(_ st: OpaquePointer?, _ i: Int32) -> String {
        sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
    }

    private func blob(_ st: OpaquePointer?, _ i: Int32) -> [Float] {
        let n = Int(sqlite3_column_bytes(st, i)) / MemoryLayout<Float>.size
        guard n > 0, let p = sqlite3_column_blob(st, i) else { return [] }
        return Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: Float.self), count: n))
    }

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    static func hash(_ s: String) -> String {
        // FNV-1a 64bit（変更検知用。暗号用途ではない）
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// 点を足すか更新して id を返す（vector が nil なら触らない）
    private func upsertNode(kind: String, key: String, name: String, description: String,
                            vector: [Float]?, hash: String?) -> Int64 {
        let sql = vector == nil
            ? "INSERT INTO nodes(kind,key,name,description,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(kind,key) DO UPDATE SET name=excluded.name, updated_at=excluded.updated_at RETURNING id"
            : "INSERT INTO nodes(kind,key,name,description,updated_at,vector,desc_hash) VALUES(?,?,?,?,?,?,?) ON CONFLICT(kind,key) DO UPDATE SET name=excluded.name, description=excluded.description, vector=excluded.vector, desc_hash=excluded.desc_hash, updated_at=excluded.updated_at RETURNING id"
        guard let st = prepare(sql) else { return -1 }
        defer { sqlite3_finalize(st) }
        bind(st, 1, kind); bind(st, 2, key); bind(st, 3, name); bind(st, 4, description)
        sqlite3_bind_int64(st, 5, now)
        if let vector { bind(st, 6, vector); bind(st, 7, hash ?? "") }
        return sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int64(st, 0) : -1
    }

    // MARK: - アプリの点

    /// アプリの点のベクトルを返す。説明文かモデルが変わったものだけ embed で作り直し、消えたアプリの点は消す。
    public func appVectors(_ apps: [AppEntry], descriptions: [String], model: String,
                           embed: (String) -> [Float]) -> [[Float]] {
        lock.lock(); defer { lock.unlock() }
        var have: [String: (String, [Float])] = [:]
        if let st = prepare("SELECT key, desc_hash, vector FROM nodes WHERE kind='app'") {
            while sqlite3_step(st) == SQLITE_ROW { have[text(st, 0)] = (text(st, 1), blob(st, 2)) }
            sqlite3_finalize(st)
        }
        try? exec("BEGIN")
        var out: [[Float]] = []
        for (a, d) in zip(apps, descriptions) {
            let h = Store.hash(model + "\n" + d)
            if let old = have[a.key], old.0 == h, !old.1.isEmpty {
                out.append(old.1)
                continue
            }
            let v = embed(d)
            out.append(v)
            _ = upsertNode(kind: "app", key: a.key, name: a.jp, description: d, vector: v, hash: h)
        }
        let live = Set(apps.map(\.key))
        if let del = prepare("DELETE FROM nodes WHERE kind='app' AND key = ?") {
            for k in have.keys where !live.contains(k) {
                sqlite3_reset(del); bind(del, 1, k); sqlite3_step(del)
            }
            sqlite3_finalize(del)
        }
        try? exec("COMMIT")
        return out
    }

    // MARK: - 例の点と chose の線

    /// 例の点を、chose の線でつながったアプリと一緒に全部読む。モデルが違う点はベクトルを作り直す。
    public func examples(model: String, embed: (String) -> [Float]) -> [(ExampleNode, [Float])] {
        lock.lock(); defer { lock.unlock() }
        var nodes: [(Int64, String, String, [Float])] = []
        if let st = prepare("SELECT id, key, desc_hash, vector FROM nodes WHERE kind='example'") {
            while sqlite3_step(st) == SQLITE_ROW {
                nodes.append((sqlite3_column_int64(st, 0), text(st, 1), text(st, 2), blob(st, 3)))
            }
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
        let up = prepare("UPDATE nodes SET vector=?, desc_hash=?, updated_at=? WHERE id=?")
        defer { sqlite3_finalize(up) }
        var out: [(ExampleNode, [Float])] = []
        for (id, q, h, v) in nodes {
            guard let ls = links[id], !ls.isEmpty else { continue }
            var vec = v
            let want = Store.hash(model + "\n" + q)
            if h != want || v.isEmpty {
                vec = embed(q)
                sqlite3_reset(up); bind(up, 1, vec); bind(up, 2, want); sqlite3_bind_int64(up, 3, now)
                sqlite3_bind_int64(up, 4, id); sqlite3_step(up)
            }
            out.append((ExampleNode(q: q, links: ls), vec))
        }
        return out
    }

    /// 「入力文 q でアプリ app を選んだ」を記録する。例の点を足し、chose の線の重み（回数）を 1 増やす。
    public func recordChoice(query q: String, app: AppEntry, appDescription: String, vector: [Float], model: String) {
        lock.lock(); defer { lock.unlock() }
        try? exec("BEGIN")
        let ex = upsertNode(kind: "example", key: q, name: q, description: q, vector: vector,
                            hash: Store.hash(model + "\n" + q))
        let ap = upsertNode(kind: "app", key: app.key, name: app.jp, description: appDescription, vector: nil, hash: nil)
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

    // MARK: - ファイル・フォルダの点と線

    /// ファイル・フォルダの点のベクトルを返す。stamp（説明文の元・日付・大きさ・モデル名のハッシュ）が変わったものだけ
    /// describe で説明文を作り（中身を読むのはここだけ）、embed し直す。消えたパスの点は消す。
    public func fileVectors(_ entries: [FileEntry], stamps: [String], describe: (Int) -> String,
                            embed: (String) -> [Float], progress: ((Int) -> Void)? = nil) -> (vecs: [[Float]], embedded: Int) {
        lock.lock(); defer { lock.unlock() }
        var have: [String: (String, [Float])] = [:]
        if let st = prepare("SELECT key, desc_hash, vector FROM nodes WHERE kind IN ('file','folder')") {
            while sqlite3_step(st) == SQLITE_ROW { have[text(st, 0)] = (text(st, 1), blob(st, 2)) }
            sqlite3_finalize(st)
        }
        try? exec("BEGIN")
        var out: [[Float]] = []
        var made = 0
        for (i, e) in entries.enumerated() {
            if let old = have[e.path], old.0 == stamps[i], !old.1.isEmpty { out.append(old.1); continue }
            let d = describe(i)
            let v = embed(d)
            out.append(v)
            made += 1
            _ = upsertNode(kind: e.isDir ? "folder" : "file", key: e.path, name: e.name, description: d, vector: v, hash: stamps[i])
            if made % 100 == 0 { try? exec("COMMIT"); try? exec("BEGIN"); progress?(made) }
        }
        let live = Set(entries.map(\.path))
        if let del = prepare("DELETE FROM nodes WHERE kind IN ('file','folder') AND key = ?") {
            for k in have.keys where !live.contains(k) { sqlite3_reset(del); bind(del, 1, k); sqlite3_step(del) }
            sqlite3_finalize(del)
        }
        try? exec("COMMIT")
        return (out, made)
    }

    /// ファイル・フォルダどうしの線（contains / co_used）を、その種類の分だけ入れ替える。組はパス
    public func replaceFileEdges(kind: String, _ pairs: [(String, String, Float)]) {
        lock.lock(); defer { lock.unlock() }
        var ids: [String: Int64] = [:]
        if let st = prepare("SELECT id, key FROM nodes WHERE kind IN ('file','folder')") {
            while sqlite3_step(st) == SQLITE_ROW { ids[text(st, 1)] = sqlite3_column_int64(st, 0) }
            sqlite3_finalize(st)
        }
        try? exec("BEGIN")
        if let del = prepare("DELETE FROM edges WHERE kind = ?") { bind(del, 1, kind); sqlite3_step(del); sqlite3_finalize(del) }
        if let st = prepare("INSERT OR REPLACE INTO edges(from_id, to_id, kind, weight, last_used) VALUES(?,?,?,?,?)") {
            for (a, b, w) in pairs {
                guard let x = ids[a], let y = ids[b] else { continue }
                sqlite3_reset(st)
                sqlite3_bind_int64(st, 1, x); sqlite3_bind_int64(st, 2, y); bind(st, 3, kind)
                sqlite3_bind_double(st, 4, Double(w)); sqlite3_bind_int64(st, 5, now)
                sqlite3_step(st)
            }
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
