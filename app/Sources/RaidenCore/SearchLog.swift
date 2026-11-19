import Foundation
import SQLite3

/// 検索の記録 1 件（入力欄を開いてから閉じるまで）。後で実際の記録で答え合わせ・重みの調整をする材料。
/// 手元の raiden.sqlite の search_log 表にだけ残し、外へは送らない。
public struct SearchLogEntry: Sendable {
    /// 出した候補 1 件（画面の並び順）
    public struct Candidate: Codable, Sendable, Equatable {
        public var kind: String      // app / file / folder
        public var key: String       // bundle id（無ければパス）かパス
        public var name: String
        public var score: Float
        public var section: String   // app / file（どちらの節に出したか）
        public init(kind: String, key: String, name: String, score: Float, section: String) {
            self.kind = kind; self.key = key; self.name = name; self.score = score; self.section = section
        }
    }
    /// 入力の移り変わり 1 回（開いてからのミリ秒）
    public struct Edit: Codable, Sendable, Equatable {
        public var q: String
        public var t: Int
        public init(q: String, t: Int) { self.q = q; self.t = t }
    }

    public var id: Int64 = 0
    public var ts: Int                  // 閉じた（選んだ）日時（UNIX 秒）
    public var query: String            // 入力の最終形
    public var edits: [Edit]            // 途中の打ち直し（最終形まで）
    public var candidates: [Candidate]  // 出した候補の上位（最大 maxRows 件）
    public var chosenKind: String?
    public var chosenKey: String?
    public var chosenName: String?
    public var chosenRank: Int?         // 画面の並びで何番目（1 始まり）
    public var dismissed: Bool          // 選ばずに閉じた
    public var notFound: Bool           // 「見つかりません」を出した（全体）
    public var notFoundApps: Bool       // アプリの節に印
    public var notFoundFiles: Bool      // ファイルの節に印
    public var ms: Double               // 最後の検索にかかった時間

    public init(ts: Int, query: String, edits: [Edit], candidates: [Candidate], chosenKind: String? = nil,
                chosenKey: String? = nil, chosenName: String? = nil, chosenRank: Int? = nil, dismissed: Bool,
                notFound: Bool, notFoundApps: Bool = false, notFoundFiles: Bool = false, ms: Double) {
        self.ts = ts; self.query = query; self.edits = edits; self.candidates = candidates
        self.chosenKind = chosenKind; self.chosenKey = chosenKey; self.chosenName = chosenName; self.chosenRank = chosenRank
        self.dismissed = dismissed; self.notFound = notFound; self.notFoundApps = notFoundApps; self.notFoundFiles = notFoundFiles
        self.ms = ms
    }
}

/// 覚えた例 1 件（言い方 → 物）
public struct LearnedExample: Sendable {
    public var query: String
    public var kind: String        // app / file / folder
    public var key: String
    public var name: String
    public var count: Int
    public var lastUsed: Int
    public init(query: String, kind: String, key: String, name: String, count: Int, lastUsed: Int) {
        self.query = query; self.kind = kind; self.key = key; self.name = name; self.count = count; self.lastUsed = lastUsed
    }
}

extension Store {
    static let searchLogSchema = """
    CREATE TABLE IF NOT EXISTS search_log(
      id INTEGER PRIMARY KEY,
      ts INTEGER NOT NULL,
      query TEXT NOT NULL,
      edits TEXT,            -- JSON [{"q": 入力, "t": 開いてからの ms}]
      candidates TEXT,       -- JSON [{"kind","key","name","score","section"}]（画面の並び順）
      chosen_kind TEXT, chosen_key TEXT, chosen_name TEXT,
      chosen_rank INTEGER,   -- 1 始まり。選ばずに閉じたら NULL
      dismissed INTEGER NOT NULL DEFAULT 0,
      not_found INTEGER NOT NULL DEFAULT 0,
      not_found_apps INTEGER NOT NULL DEFAULT 0,
      not_found_files INTEGER NOT NULL DEFAULT 0,
      ms REAL);
    CREATE INDEX IF NOT EXISTS search_log_ts ON search_log(ts);
    """

    func ensureSearchLog() {
        try? exec(Store.searchLogSchema)
    }

    // MARK: - 検索の記録

    public func logSearch(_ e: SearchLogEntry) {
        lock.lock(); defer { lock.unlock() }
        ensureSearchLog()
        guard let st = prepare("""
            INSERT INTO search_log(ts, query, edits, candidates, chosen_kind, chosen_key, chosen_name, chosen_rank,
                                   dismissed, not_found, not_found_apps, not_found_files, ms)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """) else { return }
        defer { sqlite3_finalize(st) }
        let enc = JSONEncoder()
        sqlite3_bind_int64(st, 1, Int64(e.ts))
        bind(st, 2, e.query)
        bind(st, 3, (try? enc.encode(e.edits)).map { String(decoding: $0, as: UTF8.self) } ?? "[]")
        bind(st, 4, (try? enc.encode(e.candidates)).map { String(decoding: $0, as: UTF8.self) } ?? "[]")
        func opt(_ i: Int32, _ s: String?) { if let s { bind(st, i, s) } else { sqlite3_bind_null(st, i) } }
        opt(5, e.chosenKind); opt(6, e.chosenKey); opt(7, e.chosenName)
        if let r = e.chosenRank { sqlite3_bind_int64(st, 8, Int64(r)) } else { sqlite3_bind_null(st, 8) }
        sqlite3_bind_int(st, 9, e.dismissed ? 1 : 0)
        sqlite3_bind_int(st, 10, e.notFound ? 1 : 0)
        sqlite3_bind_int(st, 11, e.notFoundApps ? 1 : 0)
        sqlite3_bind_int(st, 12, e.notFoundFiles ? 1 : 0)
        sqlite3_bind_double(st, 13, e.ms)
        sqlite3_step(st)
    }

    /// 新しい順に読む。where は追加の条件（SQL）
    public func searchLog(limit: Int = 200, onlyNotFound: Bool = false, since: Int? = nil) -> [SearchLogEntry] {
        lock.lock(); defer { lock.unlock() }
        ensureSearchLog()
        var conds: [String] = []
        if onlyNotFound { conds.append("not_found = 1 AND chosen_rank IS NULL") }
        if let since { conds.append("ts >= \(since)") }
        let w = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
        guard let st = prepare("""
            SELECT id, ts, query, edits, candidates, chosen_kind, chosen_key, chosen_name, chosen_rank,
                   dismissed, not_found, not_found_apps, not_found_files, ms
            FROM search_log \(w) ORDER BY ts DESC, id DESC LIMIT \(max(1, limit))
            """) else { return [] }
        defer { sqlite3_finalize(st) }
        let dec = JSONDecoder()
        func optText(_ i: Int32) -> String? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : text(st, i) }
        var out: [SearchLogEntry] = []
        while sqlite3_step(st) == SQLITE_ROW {
            var e = SearchLogEntry(
                ts: Int(sqlite3_column_int64(st, 1)), query: text(st, 2),
                edits: (try? dec.decode([SearchLogEntry.Edit].self, from: Data(text(st, 3).utf8))) ?? [],
                candidates: (try? dec.decode([SearchLogEntry.Candidate].self, from: Data(text(st, 4).utf8))) ?? [],
                chosenKind: optText(5), chosenKey: optText(6), chosenName: optText(7),
                chosenRank: sqlite3_column_type(st, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, 8)),
                dismissed: sqlite3_column_int(st, 9) != 0, notFound: sqlite3_column_int(st, 10) != 0,
                notFoundApps: sqlite3_column_int(st, 11) != 0, notFoundFiles: sqlite3_column_int(st, 12) != 0,
                ms: sqlite3_column_double(st, 13))
            e.id = sqlite3_column_int64(st, 0)
            out.append(e)
        }
        return out
    }

    public func searchLogCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        ensureSearchLog()
        guard let st = prepare("SELECT COUNT(*) FROM search_log") else { return 0 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }

    /// days 日より古い記録を消す。消した数を返す
    @discardableResult
    public func pruneSearchLog(days: Int, now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        ensureSearchLog()
        let cut = Int64(now.timeIntervalSince1970) - Int64(days) * 86400
        guard let st = prepare("DELETE FROM search_log WHERE ts < ?") else { return 0 }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, cut)
        sqlite3_step(st)
        return Int(sqlite3_changes(db))
    }

    public func clearSearchLog() {
        lock.lock(); defer { lock.unlock() }
        ensureSearchLog()
        try? exec("DELETE FROM search_log")
    }

    /// 見つからなかった言い方に正解を教えたら、その記録に選んだ物として書き足す（一覧から外れる）
    public func markSearchLogTaught(id: Int64, kind: String, key: String, name: String) {
        lock.lock(); defer { lock.unlock() }
        guard let st = prepare("UPDATE search_log SET chosen_kind=?, chosen_key=?, chosen_name=?, chosen_rank=0 WHERE id=?") else { return }
        defer { sqlite3_finalize(st) }
        bind(st, 1, kind); bind(st, 2, key); bind(st, 3, name); sqlite3_bind_int64(st, 4, id)
        sqlite3_step(st)
    }

    // MARK: - 覚えた例

    /// 覚えた例（example → app / file / folder の chose の線）を新しい順に
    public func learnedExamples() -> [LearnedExample] {
        lock.lock(); defer { lock.unlock() }
        guard let st = prepare("""
            SELECT x.key, t.kind, t.key, t.name, e.weight, e.last_used FROM edges e
            JOIN nodes x ON x.id = e.from_id JOIN nodes t ON t.id = e.to_id
            WHERE e.kind='chose' AND x.kind='example'
            ORDER BY e.last_used DESC
            """) else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [LearnedExample] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(LearnedExample(query: text(st, 0), kind: text(st, 1), key: text(st, 2), name: text(st, 3),
                                      count: Int(sqlite3_column_double(st, 4)), lastUsed: Int(sqlite3_column_int64(st, 5))))
        }
        return out
    }

    /// 覚えた例を 1 件消す（線だけ消し、ほかに線の無くなった例の点も消す）
    public func deleteLearned(query: String, kind: String, key: String) {
        lock.lock(); defer { lock.unlock() }
        try? exec("BEGIN")
        if let st = prepare("""
            DELETE FROM edges WHERE kind='chose'
              AND from_id = (SELECT id FROM nodes WHERE kind='example' AND key=?)
              AND to_id = (SELECT id FROM nodes WHERE kind=? AND key=?)
            """) {
            bind(st, 1, query); bind(st, 2, kind); bind(st, 3, key)
            sqlite3_step(st); sqlite3_finalize(st)
        }
        try? exec("DELETE FROM nodes WHERE kind='example' AND id NOT IN (SELECT from_id FROM edges WHERE kind='chose')")
        try? exec("COMMIT")
    }

    /// 覚えた例を全部消す
    public func clearLearned() {
        lock.lock(); defer { lock.unlock() }
        try? exec("BEGIN")
        try? exec("DELETE FROM edges WHERE kind='chose'")
        try? exec("DELETE FROM nodes WHERE kind='example'")
        try? exec("COMMIT")
    }

    /// ファイル・フォルダの点が残っているか（範囲を外した後の確かめ用）
    public func hasFileNode(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let st = prepare("SELECT 1 FROM nodes WHERE kind IN ('file','folder') AND key=?") else { return false }
        defer { sqlite3_finalize(st) }
        bind(st, 1, path)
        return sqlite3_step(st) == SQLITE_ROW
    }
}
