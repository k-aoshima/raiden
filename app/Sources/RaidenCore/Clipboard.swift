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

    /// 新しい順に探す。「#date 昨日 #from Safari 請求」のように絞り込みも書ける（ClipQuery）。
    /// 言葉は本文かコピー元のアプリ名に全部含む物（大文字小文字・全角半角は揃える）
    public func clips(matching query: String, limit: Int = 200, now: Date = Date()) -> [ClipItem] {
        clips(ClipQuery.parse(query, now: now), limit: limit)
    }

    public func clips(_ q: ClipQuery, limit: Int = 200) -> [ClipItem] {
        Array(allClips().lazy.filter(q.matches).prefix(limit))
    }

    /// 履歴の全部（新しい順、貼った先つき）。件数は設定の上限まで
    public func allClips() -> [ClipItem] {
        lock.lock(); defer { lock.unlock() }
        ensureClipTables()
        var out: [ClipItem] = []
        guard let st = prepare("SELECT id,text,src_bundle,src_app,src_title,copied_at,count FROM clips ORDER BY copied_at DESC, id DESC") else { return [] }
        while sqlite3_step(st) == SQLITE_ROW {
            let src = ClipItem.Place(bundleID: self.text(st, 2), app: self.text(st, 3), title: self.text(st, 4),
                                     at: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 5))))
            out.append(ClipItem(id: sqlite3_column_int64(st, 0), text: self.text(st, 1), source: src, count: Int(sqlite3_column_int(st, 6)), pastes: []))
        }
        sqlite3_finalize(st)
        guard !out.isEmpty, let p = prepare("SELECT clip_id,bundle,app,title,at FROM clip_pastes ORDER BY at DESC") else { return out }
        defer { sqlite3_finalize(p) }
        var idx: [Int64: Int] = [:]
        for (i, c) in out.enumerated() { idx[c.id] = i }
        while sqlite3_step(p) == SQLITE_ROW {
            guard let i = idx[sqlite3_column_int64(p, 0)] else { continue }
            out[i].pastes.append(.init(bundleID: text(p, 1), app: text(p, 2), title: text(p, 3),
                                       at: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(p, 4)))))
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

/// クリップボードの履歴の絞り込み（「#clip」の後ろに書く）。
///   #date 値    コピーした日（今日・昨日・11-14・11月・7d …。ファイルの #date と同じ書き方）
///   #from アプリ  コピーしたアプリ（名前の一部。空白を含むなら "Google Chrome"）
///   #to アプリ    貼ったアプリ
/// 残りの言葉は今までどおり本文とコピー元のアプリ名から探す
public struct ClipQuery: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case date, from, to
        public var name: String { "#" + rawValue }
        /// 別の書き方（日本語）
        public var words: [String] {
            switch self {
            case .date: return ["date", "日付", "modified", "created", "m", "c"]
            case .from: return ["from", "元", "コピー元", "f"]
            case .to: return ["to", "先", "貼り先", "貼った先"]
            }
        }
        public static func named(_ n: String) -> Kind? { allCases.first { $0.words.contains(n.lowercased()) } }
    }

    public var words: [String] = []
    public var range: ClosedRange<Int>?
    public var dateLabel: String?
    public var from: [String] = []
    public var to: [String] = []

    public init() {}
    public var isActive: Bool { range != nil || !from.isEmpty || !to.isEmpty }

    public static func parse(_ text: String, now: Date = Date()) -> ClipQuery {
        var q = ClipQuery()
        let toks = QueryFilters.tokenize(text)
        var i = 0
        while i < toks.count {
            let t = toks[i]
            if let n = QueryFilters.commandName(t) {
                if let k = Kind.named(n), i + 1 < toks.count, QueryFilters.commandName(toks[i + 1]) == nil {
                    let v = QueryFilters.unquote(toks[i + 1])
                    switch k {
                    case .date:
                        if let (r, l) = QueryFilters.parseDate(v, now: now) { q.range = r; q.dateLabel = l }
                    case .from: q.from.append(v)
                    case .to: q.to.append(v)
                    }
                    i += 2; continue
                }
                i += 1; continue   // 打ちかけのコマンドは言葉にしない
            }
            q.words.append(QueryFilters.unquote(t))
            i += 1
        }
        return q
    }

    /// 1 件が当たるか（words は本文かコピー元のアプリ名、from はコピー元、to は貼った先のどれか）
    public func matches(_ c: ClipItem) -> Bool {
        if let r = range, !r.contains(Int(c.source.at.timeIntervalSince1970)) { return false }
        let app = Describe.normalize(c.source.app), bundle = c.source.bundleID.lowercased()
        for f in from {
            let n = Describe.normalize(f)
            if !app.contains(n) && !bundle.contains(n) { return false }
        }
        for t in to {
            let n = Describe.normalize(t)
            if !c.pastes.contains(where: { Describe.normalize($0.app).contains(n) || $0.bundleID.lowercased().contains(n) }) { return false }
        }
        if !words.isEmpty {
            let body = Describe.normalize(c.text)
            for w in words.map(Describe.normalize) where !w.isEmpty && !body.contains(w) && !app.contains(w) { return false }
        }
        return true
    }
}

/// クリップボードの履歴の入力欄の一覧（「#」でコマンド、「#date 」「#from 」「#to 」で値）。件数は履歴の中で数える
public enum ClipCompletion {
    public static func palette(for text: String, clips: [ClipItem], now: Date = Date()) -> FilterCompletion.Palette? {
        let chars = Array(text)
        var s = chars.count
        while s > 0 && !chars[s - 1].isWhitespace { s -= 1 }
        let last = String(chars[s...])
        // 「#da」: コマンドの一覧
        if let n = QueryFilters.commandName(last) {
            let items = ClipQuery.Kind.allCases.filter { k in n.isEmpty || k.words.contains { $0.hasPrefix(n) } }.map(commandItem)
            return items.isEmpty ? nil : .init(mode: .clipCommands, items: items, start: s, partial: n)
        }
        // 「#from Sa」「#date 」: 値の一覧（直前のトークンがコマンド）
        var e = s
        while e > 0 && chars[e - 1].isWhitespace { e -= 1 }
        guard e < s || last.isEmpty else { return nil }
        var b = e
        while b > 0 && !chars[b - 1].isWhitespace { b -= 1 }
        guard b < e, let n = QueryFilters.commandName(String(chars[b..<e])), let k = ClipQuery.Kind.named(n) else { return nil }
        // 値を打ち終えて空白まで打ったら閉じる
        if !last.isEmpty && text.last?.isWhitespace == true { return nil }
        let others = ClipQuery.parse(String(chars[..<b]), now: now)
        let pool = clips.filter(others.matches)
        let partial = QueryFilters.unquote(last)
        var items: [FilterCompletion.Item]
        switch k {
        case .date:
            var base = FilterCompletion.dateValues.filter { FilterCompletion.hit(partial, [$0.0, $0.1]) }.map {
                FilterCompletion.Item(title: $0.1, detail: $0.0 == $0.1 ? "" : $0.0, symbol: "clock", insert: $0.0)
            }
            base += FilterCompletion.recentDays(now: now).filter { partial.isEmpty || $0.insert.hasPrefix(partial) }
            if !partial.isEmpty, let (_, l) = QueryFilters.parseDate(partial, now: now),
               !base.contains(where: { Describe.normalize($0.insert) == Describe.normalize(partial) }) {
                base.insert(.init(title: l, detail: partial, symbol: "calendar", insert: partial), at: 0)
            }
            items = base.map { it in
                var x = it
                if let (r, _) = QueryFilters.parseDate(it.insert, now: now) {
                    x.count = pool.filter { r.contains(Int($0.source.at.timeIntervalSince1970)) }.count
                }
                return x
            }
            // 1 日ずつの候補は 0 件の日を出さない
            let days = Set(FilterCompletion.recentDays(now: now).map(\.insert))
            items = items.filter { !(days.contains($0.insert) && $0.count == 0) || Describe.normalize($0.insert) == Describe.normalize(partial) }
        case .from, .to:
            var tally: [String: Int] = [:], bundles: [String: String] = [:]
            for c in pool {
                let places = k == .from ? [c.source] : c.pastes
                for a in Set(places.map(\.app)) where !a.isEmpty { tally[a, default: 0] += 1 }
                for pl in places where !pl.app.isEmpty && bundles[pl.app] == nil { bundles[pl.app] = pl.bundleID }
            }
            let np = Describe.normalize(partial)
            items = tally.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .filter { np.isEmpty || Describe.normalize($0.key).contains(np) }
                .map { .init(title: $0.key, detail: "", symbol: "app", insert: FilterCompletion.quoted($0.key), count: $0.value, bundleID: bundles[$0.key] ?? "") }
        }
        // 0 件は後ろへ（打ったとおりの値は先頭のまま）
        let typed = Describe.normalize(partial)
        items = items.enumerated().sorted { a, b in
            let ta = !typed.isEmpty && Describe.normalize(a.element.insert) == typed
            let tb = !typed.isEmpty && Describe.normalize(b.element.insert) == typed
            if ta != tb { return ta }
            let za = a.element.count == 0, zb = b.element.count == 0
            if za != zb { return !za }
            return a.offset < b.offset
        }.map(\.element)
        if items.isEmpty { return nil }
        return .init(mode: .clipValues(k.rawValue), items: items, start: b, partial: partial)
    }

    static func commandItem(_ k: ClipQuery.Kind) -> FilterCompletion.Item {
        switch k {
        case .date: return .init(title: "#date", detail: "コピーした日で絞る　例: 今日, 11-14, 11月, 7d", symbol: "clock", insert: "#date")
        case .from: return .init(title: "#from", detail: "コピーしたアプリで絞る　例: Safari", symbol: "doc.on.doc", insert: "#from")
        case .to: return .init(title: "#to", detail: "貼ったアプリで絞る　例: メール", symbol: "arrow.down.doc", insert: "#to")
        }
    }
}
