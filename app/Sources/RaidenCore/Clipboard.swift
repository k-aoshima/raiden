import Foundation
import SQLite3

/// クリップボードの履歴の 1 件（文字だけ）。どのアプリ・どの窓でコピーしたか、どこに貼ったかも持つ
public struct ClipItem: Sendable, Equatable {
    public struct Place: Sendable, Equatable {
        public var bundleID: String
        public var app: String
        public var title: String      // 窓の名前（読めなければ空）
        public var at: Date
        public init(bundleID: String, app: String, title: String, at: Date) {
            self.bundleID = bundleID; self.app = app; self.title = title; self.at = at
        }
    }
    public var id: Int64
    public var text: String
    public var source: Place
    public var count: Int            // 同じ文字を何回コピーしたか
    public var pastes: [Place]       // 貼った先（新しい順）

    public init(id: Int64, text: String, source: Place, count: Int, pastes: [Place]) {
        self.id = id; self.text = text; self.source = source; self.count = count; self.pastes = pastes
    }

    /// 一覧の 1 行に出す形（空白と改行を 1 つの空白に）
    public var oneLine: String {
        let s = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return s.count > 200 ? String(s.prefix(200)) + "…" : s
    }
}

extension Store {
    static let clipSchema = """
    CREATE TABLE IF NOT EXISTS clips(
      id INTEGER PRIMARY KEY,
      text TEXT NOT NULL,
      hash TEXT NOT NULL UNIQUE,
      src_bundle TEXT, src_app TEXT, src_title TEXT,
      copied_at INTEGER NOT NULL,
      count INTEGER NOT NULL DEFAULT 1);
    CREATE INDEX IF NOT EXISTS clips_time ON clips(copied_at);
    CREATE TABLE IF NOT EXISTS clip_pastes(
      clip_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
      bundle TEXT, app TEXT, title TEXT,
      at INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS clip_pastes_clip ON clip_pastes(clip_id, at);
    """

    /// 1 件で覚える文字の上限（これより長いコピーは覚えない。ログや巨大な表で DB を膨らませないため）
    public static let clipMaxBytes = 100_000

    func ensureClipTables() {
        try? exec(Store.clipSchema)
    }

    /// コピーを覚える。同じ文字なら一番上に上げてコピー元を新しくする。覚えた id を返す（覚えなければ nil）
    @discardableResult
    public func addClip(_ text: String, source: ClipItem.Place, keep: Int) -> Int64? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= Store.clipMaxBytes else { return nil }
        lock.lock(); defer { lock.unlock() }
        ensureClipTables()
        let sql = """
        INSERT INTO clips(text,hash,src_bundle,src_app,src_title,copied_at) VALUES(?,?,?,?,?,?)
        ON CONFLICT(hash) DO UPDATE SET src_bundle=excluded.src_bundle, src_app=excluded.src_app, src_title=excluded.src_title,
          copied_at=excluded.copied_at, count=count+1 RETURNING id
        """
        guard let st = prepare(sql) else { return nil }
        defer { sqlite3_finalize(st) }
        bind(st, 1, text); bind(st, 2, Store.hash(text)); bind(st, 3, source.bundleID); bind(st, 4, source.app); bind(st, 5, source.title)
        sqlite3_bind_int64(st, 6, Int64(source.at.timeIntervalSince1970))
        let id: Int64? = sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int64(st, 0) : nil
        // 古い物を消す（keep 件を超えた分）
        if let d = prepare("DELETE FROM clips WHERE id NOT IN (SELECT id FROM clips ORDER BY copied_at DESC, id DESC LIMIT ?)") {
            sqlite3_bind_int(d, 1, Int32(max(1, keep)))
            sqlite3_step(d); sqlite3_finalize(d)
        }
        return id
    }

    /// 履歴から選び直したとき: コピー元はそのまま、一番上に上げる
    public func touchClip(_ id: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let st = prepare("UPDATE clips SET copied_at=? WHERE id=?") else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, now); sqlite3_bind_int64(st, 2, id)
        sqlite3_step(st)
    }

    /// 貼った先を覚える
    public func recordPaste(clip id: Int64, to p: ClipItem.Place) {
        lock.lock(); defer { lock.unlock() }
        ensureClipTables()
        guard let st = prepare("INSERT INTO clip_pastes(clip_id,bundle,app,title,at) VALUES(?,?,?,?,?)") else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, id); bind(st, 2, p.bundleID); bind(st, 3, p.app); bind(st, 4, p.title)
        sqlite3_bind_int64(st, 5, Int64(p.at.timeIntervalSince1970))
        sqlite3_step(st)
        // 1 件につき新しい 20 回分だけ残す
        if let d = prepare("DELETE FROM clip_pastes WHERE clip_id=? AND rowid NOT IN (SELECT rowid FROM clip_pastes WHERE clip_id=? ORDER BY at DESC LIMIT 20)") {
            sqlite3_bind_int64(d, 1, id); sqlite3_bind_int64(d, 2, id)
            sqlite3_step(d); sqlite3_finalize(d)
        }
    }

    /// 新しい順に探す。query の空白で区切った言葉を全部含む物（大文字小文字・全角半角は揃える）
    public func clips(matching query: String, limit: Int = 200) -> [ClipItem] {
        lock.lock(); defer { lock.unlock() }
        ensureClipTables()
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { Describe.normalize(String($0)) }.filter { !$0.isEmpty }
        var out: [ClipItem] = []
        guard let st = prepare("SELECT id,text,src_bundle,src_app,src_title,copied_at,count FROM clips ORDER BY copied_at DESC, id DESC") else { return [] }
        while sqlite3_step(st) == SQLITE_ROW {
            let text = self.text(st, 1)
            if !words.isEmpty {
                let n = Describe.normalize(text)
                let app = Describe.normalize(self.text(st, 3))
                guard words.allSatisfy({ n.contains($0) || app.contains($0) }) else { continue }
            }
            let src = ClipItem.Place(bundleID: self.text(st, 2), app: self.text(st, 3), title: self.text(st, 4),
                                     at: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 5))))
            out.append(ClipItem(id: sqlite3_column_int64(st, 0), text: text, source: src, count: Int(sqlite3_column_int(st, 6)), pastes: []))
            if out.count >= limit { break }
        }
        sqlite3_finalize(st)
        guard !out.isEmpty, let p = prepare("SELECT bundle,app,title,at FROM clip_pastes WHERE clip_id=? ORDER BY at DESC LIMIT 20") else { return out }
        defer { sqlite3_finalize(p) }
        for i in out.indices {
            sqlite3_reset(p)
            sqlite3_bind_int64(p, 1, out[i].id)
            while sqlite3_step(p) == SQLITE_ROW {
                out[i].pastes.append(.init(bundleID: text(p, 0), app: text(p, 1), title: text(p, 2),
                                           at: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(p, 3)))))
            }
        }
        return out
    }

    public func clipCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        ensureClipTables()
        guard let st = prepare("SELECT COUNT(*) FROM clips") else { return 0 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int(st, 0)) : 0
    }

    public func deleteClip(_ id: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let st = prepare("DELETE FROM clips WHERE id=?") else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, id)
        sqlite3_step(st)
    }

    public func clearClips() {
        lock.lock(); defer { lock.unlock() }
        ensureClipTables()
        try? exec("DELETE FROM clip_pastes; DELETE FROM clips;")
    }
}

extension QueryFilters {
    /// クリップボードの履歴を出す書き方（#clip 請求）。専用のホットキーでも同じ状態になる
    public static let clipWords = ["clip", "cb", "クリップ", "コピー"]

    /// 「#clip 言葉」なら言葉（空も）を返す。それ以外は nil
    public static func clipText(_ q: String) -> String? {
        let t = q.drop { $0.isWhitespace }
        guard let first = t.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first,
              let n = commandName(String(first)), clipWords.contains(n) else { return nil }
        return String(t.dropFirst(first.count)).trimmingCharacters(in: .whitespaces)
    }
}
