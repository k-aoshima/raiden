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
    }

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

    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func prepare(_ sql: String) -> OpaquePointer? {
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        return st
    }

    func bind(_ st: OpaquePointer?, _ i: Int32, _ s: String) {
        sqlite3_bind_text(st, i, s, -1, Store.TRANSIENT)
    }

    func bind(_ st: OpaquePointer?, _ i: Int32, _ v: [Float]) {
        _ = v.withUnsafeBytes { sqlite3_bind_blob(st, i, $0.baseAddress, Int32($0.count), Store.TRANSIENT) }
    }

    func text(_ st: OpaquePointer?, _ i: Int32) -> String {
        sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
    }

    func blob(_ st: OpaquePointer?, _ i: Int32) -> [Float] {
        let n = Int(sqlite3_column_bytes(st, i)) / MemoryLayout<Float>.size
        guard n > 0, let p = sqlite3_column_blob(st, i) else { return [] }
        return Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: Float.self), count: n))
    }

    var now: Int64 { Int64(Date().timeIntervalSince1970) }

    static func hash(_ s: String) -> String {
        // FNV-1a 64bit（変更検知用。暗号用途ではない）
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// 点を足すか更新して id を返す（vector が nil なら触らない）
    func upsertNode(kind: String, key: String, name: String, description: String,
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

    /// 「入力文 q でファイル・フォルダ path を選んだ」を記録する。例の点を足し、例 → ファイルの chose の線の重みを 1 増やす。
    /// ファイルの点が無い（まだベクトル化していない）ときは、ベクトル無しの点を作っておく（次の fileVectors で埋まる）。
    public func recordFileChoice(query q: String, path: String, isDir: Bool, name: String, vector: [Float], model: String) {
        lock.lock(); defer { lock.unlock() }
        try? exec("BEGIN")
        let ex = upsertNode(kind: "example", key: q, name: q, description: q, vector: vector,
                            hash: Store.hash(model + "\n" + q))
        let fid = upsertNode(kind: isDir ? "folder" : "file", key: path, name: name, description: "", vector: nil, hash: nil)
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

    /// ファイル・フォルダを選んだ例を（入力文, パス）で全部読む（Engine.addFileExamples に渡す用）
    public func fileExamples() -> [(String, String)] {
        lock.lock(); defer { lock.unlock() }
        guard let st = prepare("""
            SELECT x.key, f.key FROM edges e JOIN nodes x ON x.id = e.from_id JOIN nodes f ON f.id = e.to_id
            WHERE e.kind='chose' AND x.kind='example' AND f.kind IN ('file','folder')
            ORDER BY e.last_used
            """) else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [(String, String)] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append((text(st, 0), text(st, 1))) }
        return out
    }

    // MARK: - ファイル・フォルダの点と線

    /// 保存済みのファイル・フォルダの点（パス → (desc_hash, ベクトル)）。ベクトルの無い点は空の配列
    public func storedFileVectors() -> [String: (hash: String, vec: [Float])] {
        lock.lock(); defer { lock.unlock() }
        var have: [String: (hash: String, vec: [Float])] = [:]
        if let st = prepare("SELECT key, desc_hash, vector FROM nodes WHERE kind IN ('file','folder')") {
            while sqlite3_step(st) == SQLITE_ROW { have[text(st, 0)] = (text(st, 1), blob(st, 2)) }
            sqlite3_finalize(st)
        }
        return have
    }

    /// ファイル・フォルダの点を書く（vec が nil なら点だけ作ってベクトルは触らない。線を張るため）。まとめて 1 回の BEGIN〜COMMIT
    public func saveFileNodes(_ rows: [(entry: FileEntry, description: String, vec: [Float]?, hash: String)]) {
        guard !rows.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try? exec("BEGIN")
        for r in rows {
            _ = upsertNode(kind: r.entry.isDir ? "folder" : "file", key: r.entry.path, name: r.entry.name,
                           description: r.description, vector: r.vec, hash: r.hash)
        }
        try? exec("COMMIT")
    }

    /// keys の点を消す（一覧から消えたパス）
    public func deleteFileNodes(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try? exec("BEGIN")
        if let del = prepare("DELETE FROM nodes WHERE kind IN ('file','folder') AND key = ?") {
            for k in keys { sqlite3_reset(del); bind(del, 1, k); sqlite3_step(del) }
            sqlite3_finalize(del)
        }
        try? exec("COMMIT")
    }

    /// 検索の記録で選んだファイル・フォルダの親フォルダ（パス → 選んだ回数）。ベクトル化の順番に使う
    public func chosenFolders() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Int] = [:]
        guard let st = prepare("SELECT chosen_kind, chosen_key FROM search_log WHERE chosen_kind IN ('file','folder') AND chosen_key IS NOT NULL") else { return out }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW {
            let k = text(st, 1)
            let dir = text(st, 0) == "folder" ? k : (k as NSString).deletingLastPathComponent
            out[dir, default: 0] += 1
        }
        return out
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

    // MARK: - アプリとファイルの線

    /// app → file の opens（手元のファイルを開くアプリ。OpenWithIndex）を全部張り直す。組は（アプリのキー, パス）。
    /// まだ点の無いファイルは、ベクトル無しの点として足す（fileVectors が後でベクトルを作る）
    public func replaceOpens(_ pairs: [(String, String)], apps: [AppEntry]) {
        lock.lock(); defer { lock.unlock() }
        let names = Dictionary(apps.map { ($0.key, $0.jp) }, uniquingKeysWith: { a, _ in a })
        var appIds: [String: Int64] = [:]
        try? exec("BEGIN")
        if let del = prepare("DELETE FROM edges WHERE kind = 'opens'") { sqlite3_step(del); sqlite3_finalize(del) }
        if let st = prepare("INSERT OR REPLACE INTO edges(from_id, to_id, kind, weight, last_used) VALUES(?,?,'opens',1,?)") {
            for (k, p) in pairs {
                guard let name = names[k] else { continue }  // 一覧に無いアプリ（ヘルパーなど）は張らない
                let a = appIds[k] ?? upsertNode(kind: "app", key: k, name: name, description: name, vector: nil, hash: nil)
                appIds[k] = a
                let f = upsertNode(kind: "file", key: p, name: (p as NSString).lastPathComponent,
                                   description: (p as NSString).lastPathComponent, vector: nil, hash: nil)
                guard a >= 0, f >= 0 else { continue }
                sqlite3_reset(st)
                sqlite3_bind_int64(st, 1, a); sqlite3_bind_int64(st, 2, f); sqlite3_bind_int64(st, 3, now)
                sqlite3_step(st)
            }
            sqlite3_finalize(st)
        }
        try? exec("COMMIT")
    }

    /// Raiden から開いたファイルと、実際に開いたアプリ（file → app の opened_with。重みは回数）
    public func recordOpenedWith(file path: String, appKey: String, appName: String) {
        lock.lock(); defer { lock.unlock() }
        try? exec("BEGIN")
        let f = upsertNode(kind: "file", key: path, name: (path as NSString).lastPathComponent,
                           description: (path as NSString).lastPathComponent, vector: nil, hash: nil)
        let a = upsertNode(kind: "app", key: appKey, name: appName, description: appName, vector: nil, hash: nil)
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
