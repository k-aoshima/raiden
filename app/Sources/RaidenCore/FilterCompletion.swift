import Foundation

/// 値の候補の件数を数えるための手元の一覧（Engine.filterContext で作る）。
/// 件数は QueryFilters.matches（候補の絞り込みと同じ関数）で数えるので、表示と結果が食い違わない。
public struct FilterContext: Sendable {
    public let files: [FileEntry]
    public let keys: [QueryFilters.FileKeys]
    public let appCount: Int
    /// フォルダのパスと、ファイルごとの上のフォルダ（ホームの下だけ）の番号。#path の候補の件数を数える用
    let folders: [String]
    let ancestors: [[Int32]]
    /// 最近使ったフォルダ（使った日・変更日の新しい順）
    let recentFolders: [String]

    public init(files: [FileEntry], keys: [QueryFilters.FileKeys]? = nil, appCount: Int) {
        self.files = files
        self.keys = keys ?? files.map(QueryFilters.FileKeys.init)
        self.appCount = appCount
        let home = NSHomeDirectory()
        var ids: [String: Int32] = [:], fs: [String] = []
        ancestors = files.map { e in
            var out: [Int32] = []
            guard !e.isDir else { return out }
            var p = (e.path as NSString).deletingLastPathComponent
            while p.hasPrefix(home + "/") {
                if let i = ids[p] { out.append(i) } else { let i = Int32(fs.count); ids[p] = i; fs.append(p); out.append(i) }
                p = (p as NSString).deletingLastPathComponent
            }
            return out
        }
        folders = fs
        recentFolders = files.filter(\.isDir).sorted { max($0.lastUsed, $0.mtime) > max($1.lastUsed, $1.mtime) }.prefix(6).map(\.path)
    }

    /// 条件に当てはまる物の添字
    public func indices(_ f: QueryFilters) -> [Int] {
        if !f.isActive { return Array(files.indices) }
        return files.indices.filter { f.matches(files[$0], keys: keys[$0]) }
    }

    public func count(_ f: QueryFilters) -> Int {
        (f.allowsFiles ? indices(f).count : 0) + (f.allowsApps && f.isActive && f.wantsApps ? appCount : 0)
    }
}

/// 入力欄の「#」から出す一覧（コマンドか値の候補）・ゴーストテキスト・次に付けそうなコマンドを決める。
/// 画面に依らない部分（raiden-eval --test-filters で確かめる）
public enum FilterCompletion {
    public struct Item: Sendable, Equatable {
        public let title: String      // #date、直近7日
        public let detail: String     // 期間で絞る 例: 7d, today
        public let symbol: String
        public let insert: String     // 決めたときに入れる文字（コマンドなら "#date"、値なら "7d"、次のコマンドなら "#date 7d"）
        public var alias = ""         // 一覧に小さく出す別名（#k）
        public var count: Int?        // その値で残る件数（ほかの条件の中で）。数えられなければ nil
        public var also: [String] = []  // ゴーストテキストで補う別の言い方（screenshot、Documents）
    }

    public enum Mode: Sendable, Equatable { case commands, values(QueryFilters.Command) }

    public struct Palette: Sendable {
        public let mode: Mode
        public let items: [Item]
        /// 置き換える範囲（入力欄の文字のうち、最後の「#da」や「#date 7」の部分）の始まり（文字数）
        public let start: Int
        /// 打ちかけの値（「#date 7」の「7」）
        public let partial: String
    }

    /// 検索の記録（SearchLog）から「そのコマンドでよく選ぶ値 → 回数」を返す口。設定の担当の SearchLog が入ったら差し込む
    nonisolated(unsafe) public static var usage: ((QueryFilters.Command) -> [String: Int])?

    public static let commandItems: [(QueryFilters.Command, String, String, String)] = [
        (.kind, "doc", "種類で絞る", "例: pdf, image, ss, pdf,doc"),
        (.date, "clock", "期間で絞る（使った日・変更日・作成日）", "例: 7d, today, 2026-11, 11-14..11-16"),
        (.type, "square.grid.2x2", "ファイル・フォルダ・アプリだけ", "例: f, d, app"),
        (.ext, "tag", "拡張子で絞る", "例: pdf, docx, pdf,docx"),
        (.path, "folder", "場所（パスの一部）で絞る", "例: Desktop, ~/Documents/仕事"),
        (.name, "textformat", "名前に含む文字で絞る", "例: 請求書"),
        (.modified, "pencil", "変更日で絞る", "例: 7d, 先月"),
        (.created, "calendar", "作成日で絞る", "例: 2026-11"),
    ]

    static let dateValues: [(String, String)] = [
        ("today", "今日"), ("yesterday", "昨日"), ("7d", "直近7日"), ("2w", "直近2週間"), ("1m", "直近1か月"), ("3m", "直近3か月"),
        ("今週", "今週"), ("先週", "先週"), ("今月", "今月"), ("先月", "先月"), ("今年", "今年"), ("去年", "去年"), ("1y", "直近1年"),
    ]
    static let kindValues: [(String, String, String, [String])] = [
        ("pdf", "PDF", "doc.richtext", []), ("image", "画像", "photo", ["img", "画像", "写真"]),
        ("ss", "スクショ", "camera.viewfinder", ["screenshot", "スクショ"]),
        ("movie", "動画", "film", ["video", "動画"]), ("music", "音声", "waveform", ["audio", "音声", "音楽"]),
        ("doc", "Word・文書", "doc.text", ["document", "word", "文書"]),
        ("xls", "Excel・表計算", "tablecells", ["spreadsheet", "excel", "表計算"]),
        ("ppt", "スライド", "rectangle.on.rectangle", ["presentation", "slide", "スライド"]),
        ("md", "Markdown", "text.alignleft", ["markdown"]), ("text", "テキスト", "text.alignleft", ["txt", "テキスト"]),
        ("code", "コード", "chevron.left.forwardslash.chevron.right", ["コード"]),
        ("zip", "圧縮", "archivebox", ["archive", "圧縮"]), ("3d", "3Dモデル", "cube", []),
        ("folder", "フォルダ", "folder", ["フォルダ"]), ("app", "アプリ", "app", ["application", "アプリ"]),
    ]
    /// #type の値の別の言い方（「#t #folder」「#type fol」でも当たるように）
    static let typeAlso: [String: [String]] = ["f": ["file"], "d": ["folder", "dir"], "app": ["application"]]
    static let typeValues: [(String, String, String)] = [("f", "ファイル", "doc"), ("d", "フォルダ", "folder"), ("app", "アプリ", "app")]

    static func hit(_ q: String, _ cands: [String]) -> Bool {
        let n = Describe.normalize(q)
        if n.isEmpty { return true }
        return cands.contains { Describe.normalize($0).hasPrefix(n) }
    }

    // MARK: - 一覧

    /// text: 入力欄の文字（決まったチップは含まない）。committed: チップにしたコマンド（件数を数える条件に入れる）
    public static func palette(for text: String, committed: [String] = [], context: FilterContext? = nil, now: Date = Date()) -> Palette? {
        let chars = Array(text)
        var s = chars.count
        while s > 0 && !chars[s - 1].isWhitespace { s -= 1 }
        let last = String(chars[s...])
        // 「#t #ap」: #type の値の位置に別名（#app #folder #file）を打っているなら、#type の値の候補にする
        if !last.isEmpty, let name = QueryFilters.commandName(last), !name.isEmpty {
            var e = s
            while e > 0 && chars[e - 1].isWhitespace { e -= 1 }
            var b = e
            while b > 0 && !chars[b - 1].isWhitespace { b -= 1 }
            if b < e, let cn = QueryFilters.commandName(String(chars[b..<e])), QueryFilters.command(named: cn) == .type,
               QueryFilters.isShorthandPrefix(name) {
                let base = QueryFilters.parse((committed + [String(chars[..<b])]).joined(separator: " "), now: now)
                let items = values(for: .type, partial: name, base: base, context: context, now: now)
                if !items.isEmpty { return Palette(mode: .values(.type), items: items, start: b, partial: name) }
            }
        }
        // コマンドの一覧: 最後のトークンが「#」「#da」（入力の先頭か空白の直後の「#」「＃」だけ）
        if !last.isEmpty, let name = QueryFilters.commandName(last) {
            let items = commands(matching: name)
            return items.isEmpty ? nil : Palette(mode: .commands, items: items, start: s, partial: name)
        }
        // 値の候補: 「#date 」（値がまだ無い）か「#date 7」（打ちかけ）
        var e = s
        while e > 0 && chars[e - 1].isWhitespace { e -= 1 }
        if !last.isEmpty && e == s { return nil }
        var b = e
        while b > 0 && !chars[b - 1].isWhitespace { b -= 1 }
        if b == e { return nil }
        let cmdTok = String(chars[b..<e])
        guard let cn = QueryFilters.commandName(cmdTok), let cmd = QueryFilters.command(named: cn), cmd.takesValue else { return nil }
        // 件数はチップと入力欄の残り（このコマンドより前）の条件の中で数える
        let base = QueryFilters.parse((committed + [String(chars[..<b])]).joined(separator: " "), now: now)
        let partial = QueryFilters.unquote(last)
        let items = values(for: cmd, partial: partial, base: base, context: context, now: now)
        return items.isEmpty ? nil : Palette(mode: .values(cmd), items: items, start: b, partial: partial)
    }

    public static func commands(matching name: String) -> [Item] {
        commandItems.filter { c in
            hit(name, QueryFilters.aliases.filter { $0.1 == c.0 }.map(\.0) + (c.0 == .type ? QueryFilters.typeShorthands.map(\.0) : []))
        }.map { c in
            let ja = QueryFilters.aliases.filter { $0.1 == c.0 && $0.0.unicodeScalars.contains { $0.value > 0x2FFF } }.map { QueryFilters.mark + $0.0 }
            let sh = c.0 == .type ? QueryFilters.typeShorthands.map { QueryFilters.mark + $0.0 } : []
            let alias = ([c.0.short].compactMap { $0 } + (c.0 == .path ? ["#in"] : []) + ja.prefix(1) + sh).joined(separator: " ")
            return Item(title: c.0.name, detail: c.3.isEmpty ? c.2 : c.2 + "  " + c.3, symbol: c.1, insert: c.0.name, alias: alias)
        }
    }

    /// 値の候補。context があれば、ほかの条件（base からこのコマンドを外した物）の中での件数を添え、
    /// よく使う値（usage）→ 件数のある値 → 0 件の値（下に回す）の順に並べる
    public static func values(for cmd: QueryFilters.Command, partial: String, base: QueryFilters,
                              context ctx: FilterContext?, now: Date) -> [Item] {
        let others = base.without(cmd)
        let pool = ctx.map { $0.indices(others) }   // ほかの条件に当てはまる物（一度だけ数える）
        func count(_ v: String) -> Int? {
            guard let ctx, let pool else { return nil }
            var one = QueryFilters()
            guard one.apply(cmd, v, now: now) != nil else { return 0 }
            if cmd == .type || cmd == .kind, one.wantsApps, one.types.count + one.kinds.count == 1 {
                return others.allowsApps || (others.without(.type).without(.kind).allowsApps) ? ctx.appCount : 0
            }
            var n = 0
            for i in pool where one.matches(ctx.files[i], keys: ctx.keys[i]) { n += 1 }
            return n
        }
        var out: [Item]
        var sortByCount = false
        switch cmd {
        case .date, .modified, .created:
            out = dateValues.filter { hit(partial, [$0.0, $0.1]) }.map {
                Item(title: $0.1, detail: $0.0 == $0.1 ? "" : $0.0, symbol: "clock", insert: $0.0, count: count($0.0))
            }
            // 手で打った日付（2026-11、11-14..11-16）が読めればそれを先頭に
            if !partial.isEmpty, let (_, l) = QueryFilters.parseDate(partial, now: now),
               !out.contains(where: { Describe.normalize($0.insert) == Describe.normalize(partial) }) {
                out.insert(Item(title: l, detail: partial, symbol: "calendar", insert: partial, count: count(partial)), at: 0)
            }
        case .kind, .ext:
            // カンマ区切りの最後の 1 つだけを候補で補う（pdf,do → pdf,doc）
            let ps = partial.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let done = Array(ps.dropLast())
            let cur = ps.last ?? ""
            let pre = done.isEmpty ? "" : done.joined(separator: ",") + ","
            if cmd == .kind {
                out = kindValues.filter { hit(cur, [$0.0, $0.1] + $0.3) && !done.contains($0.0) }.map {
                    Item(title: $0.1, detail: pre + $0.0, symbol: $0.2, insert: pre + $0.0, count: count($0.0), also: $0.3)
                }
                // 手元に無い種類は、打ちかけで当たったときだけ出す
                if cur.isEmpty && ctx != nil { out = out.filter { ($0.count ?? 1) > 0 } }
            } else {
                // 手元にある拡張子を多い順に（ほかの条件の中で）
                var tally: [String: Int] = [:]
                if let ctx, let pool { for i in pool where !ctx.files[i].isDir && !ctx.keys[i].ext.isEmpty { tally[ctx.keys[i].ext, default: 0] += 1 } }
                let common = ["pdf", "docx", "xlsx", "png", "jpg", "md", "txt", "zip", "mov", "csv"]
                let exts = ctx == nil ? common : tally.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(16).map(\.key)
                let n = Describe.normalize(cur)
                out = exts.filter { (n.isEmpty || $0.hasPrefix(n)) && !done.contains($0) }.map {
                    Item(title: "." + $0, detail: pre + $0, symbol: "tag", insert: pre + $0, count: ctx == nil ? nil : tally[$0] ?? 0)
                }
            }
            sortByCount = true
        case .type:
            out = typeValues.filter { hit(partial, [$0.0, $0.1] + (typeAlso[$0.0] ?? [])) }.map {
                Item(title: $0.1, detail: $0.0, symbol: $0.2, insert: $0.0, count: count($0.0), also: typeAlso[$0.0] ?? [])
            }
        case .path:
            out = placeItems(partial: partial, others: others, pool: pool, ctx: ctx)
        case .name:
            return []
        }
        // 並べ方: よく使う値 → 件数のある値（種類・拡張子は多い順）→ 0 件
        let use = usage?(cmd) ?? [:]
        let ranked = out.enumerated().sorted { a, b in
            let ua = use[a.element.insert] ?? 0, ub = use[b.element.insert] ?? 0
            if ua != ub { return ua > ub }
            let za = a.element.count == 0, zb = b.element.count == 0
            if za != zb { return !za }
            if sortByCount, let ca = a.element.count, let cb = b.element.count, ca != cb { return ca > cb }
            return a.offset < b.offset
        }
        return ranked.map(\.element)
    }

    /// #path の候補: 中のファイルが多いフォルダ（ほかの条件の中で）と最近使ったフォルダ。context が無ければ探す場所だけ
    static func placeItems(partial: String, others: QueryFilters, pool: [Int]?, ctx: FilterContext?) -> [Item] {
        var cands: [(String, Int?)] = []
        if let ctx, let pool {
            var n = [Int](repeating: 0, count: ctx.folders.count)
            for i in pool { for a in ctx.ancestors[i] { n[Int(a)] += 1 } }
            let top = n.indices.filter { n[$0] > 0 }.sorted { n[$0] != n[$1] ? n[$0] > n[$1] : ctx.folders[$0] < ctx.folders[$1] }.prefix(40)
            var byPath: [String: Int] = [:]
            for (i, p) in ctx.folders.enumerated() where n[i] > 0 { byPath[p] = n[i] }
            cands = top.map { (ctx.folders[$0], n[$0]) } + ctx.recentFolders.map { ($0, byPath[$0] ?? 0) }
        } else {
            cands = FileCatalog.defaultRoots.map { ($0, nil) }
        }
        let n = Describe.normalize(partial)
        var seen = Set<String>(), out: [Item] = []
        for (p, c) in cands where seen.insert(p).inserted {
            let short = (p as NSString).abbreviatingWithTildeInPath
            let last = (p as NSString).lastPathComponent
            guard n.isEmpty || Describe.normalize(last).hasPrefix(n) || Describe.normalize(short).contains(n) else { continue }
            out.append(Item(title: last, detail: short, symbol: "folder", insert: short.contains(" ") ? "\"\(short)\"" : short,
                            count: c, also: [last]))
            if out.count >= 8 { break }
        }
        return out
    }

    // MARK: - ゴーストテキスト

    /// 打ちかけの値の補完（「#date 7」→「d（直近7日）」、「#kind sc」→「reenshot → ss（スクショ）」）。
    /// 返すのは補う文字（薄く出す）と、→ / Tab で決めたときの候補
    public static func ghost(_ p: Palette) -> (text: String, item: Item)? {
        guard case .values = p.mode, !p.partial.isEmpty else { return nil }
        let n = Describe.normalize(p.partial)
        let items = p.items.filter { $0.count != 0 } + p.items.filter { $0.count == 0 }
        for it in items {
            let forms = [it.insert] + it.also + [it.title]
            guard let f = forms.first(where: { Describe.normalize($0).hasPrefix(n) && $0.count >= p.partial.count }) else { continue }
            var t = String(f.dropFirst(p.partial.count))
            if f != it.insert { t += " → " + it.insert }
            if it.title != it.insert && it.title != f { t += "（\(it.title)）" }
            if t.isEmpty { return nil }   // もう打ち終えている
            return (t, it)
        }
        return nil
    }

    // MARK: - 決める

    /// 一覧の 1 行を決めたときの入力欄の文字と、チップにするコマンド（値まで決まったときだけ）
    public static func accept(_ item: Item, palette p: Palette, text: String) -> (text: String, commit: String?) {
        let head = String(text.prefix(p.start))
        switch p.mode {
        case .commands:
            guard let cmd = QueryFilters.command(named: String(item.insert.dropFirst())) else { return (text, nil) }
            return (head + cmd.name + " ", nil)
        case .values(let cmd):
            return (tidy(head), cmd.name + " " + item.insert)
        }
    }

    static func tidy(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "" : t + " "
    }

    /// 打ち終えたコマンド（空白まで打った「#date 2026-11-14 」）を入力欄から抜き出してチップにする。
    /// 最後が空白でなければ何もしない（打ちかけを消さない）。読めない値のコマンドは残す（入力欄の下に知らせる）
    public static func extractCommitted(_ text: String, now: Date = Date()) -> (commands: [String], text: String)? {
        guard text.last?.isWhitespace == true else { return nil }
        let toks = QueryFilters.expandShorthands(QueryFilters.tokenize(text))
        var cmds: [String] = [], rest: [String] = []
        var i = 0
        while i < toks.count {
            if let n = QueryFilters.commandName(toks[i]), let c = QueryFilters.command(named: n),
               i + 1 < toks.count, QueryFilters.commandName(toks[i + 1]) == nil {
                var probe = QueryFilters()
                if probe.apply(c, QueryFilters.unquote(toks[i + 1]), now: now) != nil {
                    cmds.append(c.name + " " + toks[i + 1]); i += 2; continue
                }
            }
            rest.append(toks[i]); i += 1
        }
        if cmds.isEmpty { return nil }
        return (cmds, rest.isEmpty ? "" : rest.joined(separator: " ") + " ")
    }

    // MARK: - 次に付けそうなコマンド

    /// 値まで決まった後に、次に付けそうなコマンド（insert は「#date today」のようにコマンドと値の組）。件数 0 は出さない
    public static func next(_ f: QueryFilters, context ctx: FilterContext?, now: Date = Date()) -> [Item] {
        guard f.isActive, !f.wantsApps, let ctx else { return [] }
        let pool = ctx.indices(f)
        if pool.isEmpty { return [] }
        func count(_ cmd: QueryFilters.Command, _ v: String) -> Int {
            var one = QueryFilters()
            _ = one.apply(cmd, v, now: now)
            return pool.reduce(0) { $0 + (one.matches(ctx.files[$1], keys: ctx.keys[$1]) ? 1 : 0) }
        }
        var out: [Item] = []
        let hasDate = !f.dates.isEmpty
        let hasKind = !f.kinds.isEmpty || !f.kindExts.isEmpty || !f.exts.isEmpty
        if !hasDate {
            for (v, l) in [("today", "今日"), ("7d", "直近7日"), ("1m", "直近1か月")] where out.count < 2 {
                let c = count(.date, v)
                if c > 0 && c < pool.count { out.append(Item(title: "#date \(l)", detail: "", symbol: "clock", insert: "#date \(v)", count: c)) }
            }
        }
        if !hasKind {
            let ks = kindValues.filter { !["folder", "app"].contains($0.0) }.map { ($0, count(.kind, $0.0)) }
                .filter { $0.1 > 0 && $0.1 < pool.count }.sorted { $0.1 > $1.1 }.prefix(2)
            for (k, c) in ks { out.append(Item(title: "#kind \(k.1)", detail: "", symbol: k.2, insert: "#kind \(k.0)", count: c)) }
        }
        if hasDate && hasKind && f.paths.isEmpty,
           let p = placeItems(partial: "", others: f, pool: pool, ctx: ctx).first(where: { ($0.count ?? 0) > 0 && ($0.count ?? 0) < pool.count }) {
            out.append(Item(title: "#path \(p.title)", detail: "", symbol: "folder", insert: "#path \(p.insert)", count: p.count))
        }
        return Array(out.prefix(3))
    }
}
