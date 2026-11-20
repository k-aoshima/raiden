import Foundation

/// 値の候補の件数と、手元に多い拡張子・場所・最近使った物を返す口。入力欄はこれだけを見る。
/// 今は手元の一覧（FilterContext）が答える。一覧が無くなったら、Spotlight 側の担当がこれに合わせた物を作って
/// FilterInput.context に渡す。答えられない物は nil / [] を返せば、件数なしで候補だけ出す。
/// 件数が後から届く（問い合わせが非同期）ときは、届いたら FilterInput.sourceDidUpdate() を呼べば出し直す
public protocol FilterSource {
    /// アプリの数（#type app の件数）
    var appCount: Int { get }
    /// cmd の値ごとに、others（ほかの条件）＋その値で残る件数。数えられなければ nil（件数なしで出す）
    func counts(_ cmd: QueryFilters.Command, values: [String], within others: QueryFilters, now: Date) -> [String: Int]?
    /// 条件に当てはまるファイル・フォルダの数。数えられなければ nil
    func total(_ f: QueryFilters) -> Int?
    /// others の中で多い拡張子（多い順）。nil なら覚えた値と決まった一覧で出す
    func topExtensions(within others: QueryFilters, limit: Int) -> [(String, Int)]?
    /// others の中で中身の多いフォルダ（絶対パス、多い順）
    func topFolders(within others: QueryFilters, limit: Int) -> [(String, Int)]?
    /// 最近使ったフォルダ（絶対パス、新しい順）
    func recentFolders(limit: Int) -> [String]
    /// 最近使ったファイル・フォルダ（絶対パス、新しい順）。#with・#near の値の候補
    func recentFiles(limit: Int) -> [String]
}

public extension FilterSource {
    func counts(_ cmd: QueryFilters.Command, values: [String], within others: QueryFilters, now: Date) -> [String: Int]? { nil }
    func total(_ f: QueryFilters) -> Int? { nil }
    func topExtensions(within others: QueryFilters, limit: Int) -> [(String, Int)]? { nil }
    func topFolders(within others: QueryFilters, limit: Int) -> [(String, Int)]? { nil }
    func recentFolders(limit: Int) -> [String] { [] }
    func recentFiles(limit: Int) -> [String] { [] }
}

/// 値の候補の件数を数えるための手元の一覧（Engine.filterContext で作る）。FilterSource の今の実装。
/// 件数は QueryFilters.matches（候補の絞り込みと同じ関数）で数えるので、表示と結果が食い違わない
public struct FilterContext: FilterSource, Sendable {
    public let files: [FileEntry]
    public let keys: [QueryFilters.FileKeys]
    public let appCount: Int
    /// フォルダのパスと、ファイルごとの上のフォルダ（ホームの下だけ）の番号。#path の候補の件数を数える用
    let folders: [String]
    let ancestors: [[Int32]]
    /// 最近使ったフォルダ・ファイル（使った日・変更日の新しい順）
    let recentDirs: [String]
    let recentItems: [String]

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
        let byUse = files.sorted { max($0.lastUsed, $0.mtime) > max($1.lastUsed, $1.mtime) }
        recentDirs = byUse.lazy.filter(\.isDir).prefix(6).map(\.path)
        recentItems = byUse.prefix(30).map(\.path)
    }

    /// 条件に当てはまる物の添字（#with・#near はここでは見ない）
    public func indices(_ f: QueryFilters) -> [Int] {
        if !f.isActive { return Array(files.indices) }
        return files.indices.filter { f.matches(files[$0], keys: keys[$0]) }
    }

    public func count(_ f: QueryFilters) -> Int {
        (f.allowsFiles ? indices(f).count : 0) + (f.allowsApps && f.isActive && f.wantsApps ? appCount : 0)
    }

    public func total(_ f: QueryFilters) -> Int? { f.allowsFiles ? indices(f).count : 0 }

    public func counts(_ cmd: QueryFilters.Command, values: [String], within others: QueryFilters, now: Date) -> [String: Int]? {
        let pool = indices(others)
        var out: [String: Int] = [:]
        for v in values {
            var one = QueryFilters()
            guard one.apply(cmd, v, now: now) != nil else { out[v] = 0; continue }
            var n = 0
            for i in pool where one.matches(files[i], keys: keys[i]) { n += 1 }
            out[v] = n
        }
        return out
    }

    public func topExtensions(within others: QueryFilters, limit: Int) -> [(String, Int)]? {
        var tally: [String: Int] = [:]
        for i in indices(others) where !files[i].isDir && !keys[i].ext.isEmpty { tally[keys[i].ext, default: 0] += 1 }
        return tally.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map { ($0.key, $0.value) }
    }

    public func topFolders(within others: QueryFilters, limit: Int) -> [(String, Int)]? {
        var n = [Int](repeating: 0, count: folders.count)
        for i in indices(others) { for a in ancestors[i] { n[Int(a)] += 1 } }
        return n.indices.filter { n[$0] > 0 }.sorted { n[$0] != n[$1] ? n[$0] > n[$1] : folders[$0] < folders[$1] }
            .prefix(limit).map { (folders[$0], n[$0]) }
    }

    /// フォルダの中の件数（others の中で）。topFolders に無い最近のフォルダの件数を出す用
    func folderCount(_ p: String, within others: QueryFilters) -> Int {
        guard let fi = folders.firstIndex(of: p) else { return 0 }
        return indices(others).reduce(0) { $0 + (ancestors[$1].contains(Int32(fi)) ? 1 : 0) }
    }

    public func recentFolders(limit: Int) -> [String] { Array(recentDirs.prefix(limit)) }
    public func recentFiles(limit: Int) -> [String] { Array(recentItems.prefix(limit)) }
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
        public var commits: [String] = []  // 決めたらまとめてチップにするコマンド（よく使う組み合わせ・保存した名前）
        public var badge = ""         // 一覧の行の右に小さく出す印（よく使う・保存）
    }

    public enum Mode: Sendable, Equatable { case commands, values(QueryFilters.Command), save, alias }

    public struct Palette: Sendable {
        public let mode: Mode
        public let items: [Item]
        /// 置き換える範囲（入力欄の文字のうち、最後の「#da」や「#date 7」の部分）の始まり（文字数）
        public let start: Int
        /// 打ちかけの値（「#date 7」の「7」）。保存のときは名前
        public let partial: String
    }

    public static let commandItems: [(QueryFilters.Command, String, String, String)] = [
        (.kind, "doc", "種類で絞る", "例: pdf, image, ss, pdf,doc"),
        (.date, "clock", "期間で絞る（使った日・変更日・作成日）", "例: 7d, today, 11-14, 11月, 11-1..11-14"),
        (.type, "square.grid.2x2", "ファイル・フォルダ・アプリだけ", "例: f, d, app"),
        (.ext, "tag", "拡張子で絞る", "例: pdf, docx, pdf,docx"),
        (.path, "folder", "場所（パスの一部）で絞る", "例: Desktop, ~/Documents/仕事"),
        (.name, "textformat", "名前に含む文字で絞る", "例: 請求書"),
        (.modified, "pencil", "変更日で絞る", "例: 7d, 先月"),
        (.created, "calendar", "作成日で絞る", "例: 2026-11"),
        (.with, "link", "そのファイルと同じころに使った物", "例: ~/Documents/見積書.pdf"),
        (.near, "point.3.connected.trianglepath.dotted", "そのファイルと同じプロジェクトの物", "例: ~/Project/raiden/README.md"),
    ]

    static let dateValues: [(String, String)] = [
        ("today", "今日"), ("yesterday", "昨日"), ("7d", "直近7日"), ("2w", "直近2週間"), ("1m", "直近1か月"), ("3m", "直近3か月"),
        ("今週", "今週"), ("先週", "先週"), ("今月", "今月"), ("先月", "先月"), ("今年", "今年"), ("去年", "去年"), ("1y", "直近1年"),
    ]
    /// おととい〜13 日前の 1 日ずつの候補（insert は「11-18」）
    static func recentDays(now: Date) -> [Item] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let wd = ["日", "月", "火", "水", "木", "金", "土"]
        return (2...13).compactMap { n in
            guard let d = cal.date(byAdding: .day, value: -n, to: today) else { return nil }
            let c = cal.dateComponents([.month, .day, .weekday], from: d)
            let v = "\(c.month!)-\(c.day!)"
            return Item(title: "\(v)（\(wd[c.weekday! - 1])）", detail: n == 2 ? "おととい" : "\(n)日前", symbol: "calendar", insert: v)
        }
    }

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
    /// 手元の一覧も覚えた値も無いときの #path の候補
    static let fallbackPlaces = ["~/Desktop", "~/Documents", "~/Downloads"]
    /// 「#」の直後に出す、よく使う組み合わせ・保存した名前の数
    public static let comboRows = 3, savedRows = 4

    static func hit(_ q: String, _ cands: [String]) -> Bool {
        let n = Describe.normalize(q)
        if n.isEmpty { return true }
        return cands.contains { Describe.normalize($0).hasPrefix(n) }
    }

    /// 値として入れる形（空白を含めば "" で囲む）
    static func quoted(_ v: String) -> String { v.contains(where: \.isWhitespace) ? "\"\(v)\"" : v }

    // MARK: - 一覧

    /// text: 入力欄の文字（決まったチップは含まない）。committed: チップにしたコマンド（件数を数える条件に入れる）。
    /// context: 件数を数える口（無ければ件数なし）。memory: 検索の記録から覚えた使い方（よく使う組み合わせ・値・場所）
    /// 一覧に出す件数の文字。数える上限まで行ったら「1万以上」（それより多いかは数えていないので、上限の数そのものは出さない）
    public static func countText(_ c: Int) -> String {
        c >= SpotlightSearch.countCap ? "1万以上" : "\(c)"
    }

    public static func palette(for text: String, committed: [String] = [], context: FilterSource? = nil,
                               memory: FilterMemory = .empty, now: Date = Date()) -> Palette? {
        let chars = Array(text)
        // 「#保存 名前」: 今の条件（チップ）に名前を付けて保存する
        let toks = text.split(separator: " ", omittingEmptySubsequences: true)
        if let si = toks.firstIndex(where: { t in QueryFilters.commandName(String(t)).map { QueryFilters.saveWords.contains($0) } ?? false }) {
            let startIdx = text.distance(from: text.startIndex, to: toks[si].startIndex)
            let name = SavedFilter.clean(toks[(si + 1)...].joined(separator: " "))
            return Palette(mode: .save, items: [saveItem(name: name, committed: committed)], start: startIdx, partial: name)
        }
        // 「#alias 言い方」: 辞書に足す言い方を決める（決めたら入力欄が「→ どれに？」の選ぶ状態になる）
        if let ai = toks.firstIndex(where: { t in QueryFilters.commandName(String(t)).map { QueryFilters.aliasWords.contains($0) } ?? false }) {
            let startIdx = text.distance(from: text.startIndex, to: toks[ai].startIndex)
            let phrase = toks[(ai + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return Palette(mode: .alias, items: aliasItems(phrase: phrase, memory: memory), start: startIdx, partial: phrase)
        }
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
                let items = values(for: .type, partial: name, base: base, context: context, memory: memory, now: now)
                if !items.isEmpty { return Palette(mode: .values(.type), items: items, start: b, partial: name) }
            }
        }
        // コマンドの一覧: 最後のトークンが「#」「#da」（入力の先頭か空白の直後の「#」「＃」だけ）
        if !last.isEmpty, let name = QueryFilters.commandName(last) {
            var items = shortcuts(matching: name, committed: committed, memory: memory) + commands(matching: name)
            // 今の条件を保存する行（チップがあるときだけ）
            if !committed.isEmpty && (name.isEmpty || hit(name, QueryFilters.saveWords)) {
                items.append(Item(title: "#保存", detail: "今の条件に名前を付けて保存  例: #保存 仕事のPDF（⌘S）", symbol: "bookmark",
                                  insert: "#保存", alias: "#save"))
            }
            if hit(name, QueryFilters.clipWords) {
                items.append(Item(title: "#clip", detail: "クリップボードの履歴  専用のキー（初期値 ⌥V）でもすぐ開けます", symbol: "doc.on.clipboard",
                                  insert: "#clip", alias: "#cb #コピー"))
            }
            if hit(name, QueryFilters.aliasWords) {
                items.append(Item(title: "#alias", detail: "言い方を辞書に足す  例: #alias 黒い画面 → ↩ で行き先を選ぶ", symbol: "book",
                                  insert: "#alias", alias: "#dict #辞書"))
            }
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
        let items = values(for: cmd, partial: partial, base: base, context: context, memory: memory, now: now)
        return items.isEmpty ? nil : Palette(mode: .values(cmd), items: items, start: b, partial: partial)
    }

    /// 「#保存 名前」の 1 行。insert が空なら決められない（名前が無い・使えない・条件が無い）
    static func saveItem(name: String, committed: [String]) -> Item {
        if committed.isEmpty {
            return Item(title: "保存する条件がありません", detail: "先に #ext pdf などを決めてから #保存 名前", symbol: "exclamationmark.circle", insert: "")
        }
        if name.isEmpty {
            return Item(title: "名前を打って ↩ で保存", detail: committed.joined(separator: " "), symbol: "bookmark", insert: "")
        }
        if let pr = SavedFilter.problem(name: name) {
            return Item(title: pr, detail: committed.joined(separator: " "), symbol: "exclamationmark.circle", insert: "")
        }
        let over = SavedFilters.find(name) != nil
        return Item(title: "#\(name) として保存" + (over ? "（上書き）" : ""), detail: committed.joined(separator: " "),
                    symbol: "bookmark", insert: name, commits: committed)
    }

    /// 「#alias 」の候補: 打った言い方（↩ で行き先を選ぶ）と、選ばずに閉じた・見つからなかった言い方（記録から）
    static func aliasItems(phrase: String, memory: FilterMemory) -> [Item] {
        var out: [Item] = []
        if !phrase.isEmpty {
            let has = PhraseDictionary.all.first { Describe.normalize($0.phrase) == Describe.normalize(phrase) }
            out.append(Item(title: "「\(phrase)」→ どれに？", detail: has.map { "今は → \($0.name)（選ぶと置き換えます）" } ?? "↩ で行き先のアプリ・ファイルを選ぶ",
                            symbol: "book", insert: phrase))
        }
        for q in memory.missed where q != phrase && hit(phrase, [q]) {
            out.append(Item(title: q, detail: "最近、選ばずに閉じた言い方", symbol: "text.magnifyingglass", insert: q))
            if out.count >= 8 { break }
        }
        if out.isEmpty {
            out.append(Item(title: "言い方を打って ↩", detail: "例: #alias 黒い画面 → ターミナル", symbol: "book", insert: ""))
        }
        return out
    }

    /// 「#」の直後に出す、保存した名前とよく使う組み合わせ。打ちかけ（「#仕」）なら保存した名前の頭で絞る。
    /// 組み合わせは今のチップを含む物の残りだけ（同じコマンドを重ねない）
    public static func shortcuts(matching name: String, committed: [String] = [], memory: FilterMemory = .empty) -> [Item] {
        var out: [Item] = []
        let have = Set(committed.map { normCmd($0) })
        let haveCmds = Set(committed.compactMap { QueryFilters.parse($0).order.first })
        for sf in SavedFilters.all where hit(name, [sf.name]) {
            let rest = sf.commands.filter { !have.contains(normCmd($0)) }
            if rest.isEmpty { continue }
            out.append(Item(title: "#" + sf.name, detail: sf.text, symbol: "bookmark", insert: "#" + sf.name, commits: rest, badge: "保存"))
            if out.count >= savedRows { break }
        }
        guard name.isEmpty else { return out }
        var n = 0
        for c in memory.combos {
            let normed = c.commands.map(normCmd)
            guard have.isSubset(of: Set(normed)) else { continue }
            let rest = c.commands.filter { !have.contains(normCmd($0)) }
            let restCmds = rest.compactMap { QueryFilters.parse($0).order.first }
            if rest.isEmpty || restCmds.contains(where: haveCmds.contains) { continue }
            if out.contains(where: { $0.commits == rest }) { continue }
            out.append(Item(title: rest.joined(separator: " "), detail: "よく使う組み合わせ・\(c.count) 回", symbol: "clock.arrow.circlepath",
                            insert: rest.joined(separator: " "), commits: rest, badge: "よく使う"))
            n += 1
            if n >= comboRows { break }
        }
        return out
    }

    /// コマンド 1 つを比べる形（#e pdf と #ext pdf を同じに）
    static func normCmd(_ s: String) -> String {
        let f = QueryFilters.parse(s)
        return f.parsed.first.flatMap(FilterMemory.canonical).map(Describe.normalize) ?? Describe.normalize(s)
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
    /// よく使う値（memory）→ 件数のある値 → 0 件の値（下に回す）の順に並べる
    public static func values(for cmd: QueryFilters.Command, partial: String, base: QueryFilters,
                              context src: FilterSource?, memory: FilterMemory = .empty, now: Date) -> [Item] {
        let others = base.without(cmd)
        /// 候補の値をまとめて数える（アプリだけの値はアプリの数）
        func counted(_ items: [Item], key: (Item) -> String = { $0.insert }) -> [Item] {
            guard let src else { return items }
            let vs = items.map(key)
            let got = src.counts(cmd, values: vs, within: others, now: now)
            return items.map { it in
                var x = it
                var one = QueryFilters()
                let v = key(it)
                if (cmd == .type || cmd == .kind), one.apply(cmd, v, now: now) != nil, one.wantsApps, one.types.count + one.kinds.count == 1 {
                    x.count = others.allowsApps || others.without(.type).without(.kind).allowsApps ? src.appCount : 0
                } else if let got {
                    x.count = got[v] ?? 0
                }
                return x
            }
        }
        var out: [Item]
        var sortByCount = false
        var keepOrder = false
        switch cmd {
        case .date, .modified, .created:
            out = dateValues.filter { hit(partial, [$0.0, $0.1]) }.map {
                Item(title: $0.1, detail: $0.0 == $0.1 ? "" : $0.0, symbol: "clock", insert: $0.0)
            }
            // 日付を打たずに選べるよう、おととい〜13 日前を 1 日ずつ（「11-18（火）」）。打ちかけなら当たる物だけ
            out += recentDays(now: now).filter { partial.isEmpty || $0.insert.hasPrefix(partial) || $0.title.hasPrefix(partial) }
            // 手で打った日付（2026-11、11-14..11-16）が読めればそれを先頭に
            if !partial.isEmpty, let (_, l) = QueryFilters.parseDate(partial, now: now),
               !out.contains(where: { Describe.normalize($0.insert) == Describe.normalize(partial) }) {
                out.insert(Item(title: l, detail: partial, symbol: "calendar", insert: partial), at: 0)
            }
            out = counted(out)
            // 1 日ずつの候補は、数えて 0 件の日を出さない（一覧が長くなるだけなので）
            let days = Set(recentDays(now: now).map(\.insert))
            out = out.filter { !(days.contains($0.insert) && $0.count == 0 && $0.insert != partial) }
        case .kind, .ext:
            // カンマ区切りの最後の 1 つだけを候補で補う（pdf,do → pdf,doc）
            let ps = partial.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let done = Array(ps.dropLast())
            let cur = ps.last ?? ""
            let pre = done.isEmpty ? "" : done.joined(separator: ",") + ","
            if cmd == .kind {
                out = kindValues.filter { hit(cur, [$0.0, $0.1] + $0.3) && !done.contains($0.0) }.map {
                    Item(title: $0.1, detail: pre + $0.0, symbol: $0.2, insert: pre + $0.0, also: $0.3)
                }
                out = counted(out, key: { String($0.insert.split(separator: ",").last ?? "") })
                // 手元に無い種類は、打ちかけで当たったときだけ出す
                if cur.isEmpty && out.contains(where: { $0.count != nil }) { out = out.filter { ($0.count ?? 1) > 0 } }
            } else {
                // 手元に多い拡張子（ほかの条件の中で）。数えられなければ、よく使った拡張子と決まった一覧
                let top = src?.topExtensions(within: others, limit: 16)
                var exts: [(String, Int?)] = top.map { $0.map { ($0.0, Optional($0.1)) } } ?? []
                let used = (memory.values[.ext] ?? [:]).sorted { $0.value > $1.value }.map(\.key)
                for u in used.prefix(6) where !exts.contains(where: { $0.0 == u }) { exts.append((u, top == nil ? nil : 0)) }
                if top == nil { for c in ["pdf", "docx", "xlsx", "png", "jpg", "md", "txt", "zip", "mov", "csv"] where !exts.contains(where: { $0.0 == c }) { exts.append((c, nil)) } }
                let n = Describe.normalize(cur)
                out = exts.filter { (n.isEmpty || $0.0.hasPrefix(n)) && !done.contains($0.0) }.map {
                    Item(title: "." + $0.0, detail: pre + $0.0, symbol: "tag", insert: pre + $0.0, count: $0.1)
                }
            }
            sortByCount = true
        case .type:
            out = counted(typeValues.filter { hit(partial, [$0.0, $0.1] + (typeAlso[$0.0] ?? [])) }.map {
                Item(title: $0.1, detail: $0.0, symbol: $0.2, insert: $0.0, also: typeAlso[$0.0] ?? [])
            })
        case .path:
            out = placeItems(partial: partial, others: others, src: src, memory: memory, now: now)
            keepOrder = true
        case .with, .near:
            return fileItems(partial: partial, src: src, memory: memory)
        case .name:
            return []
        }
        // 並べ方: よく使う値 → 件数のある値（種類・拡張子は多い順）→ 0 件
        let typed = Describe.normalize(partial)
        let ranked = out.enumerated().sorted { a, b in
            // 打ったとおりの値（「11-1」）は件数が 0 でも先頭（Enter で打ったものが決まるように）
            let ta = !typed.isEmpty && Describe.normalize(a.element.insert) == typed
            let tb = !typed.isEmpty && Describe.normalize(b.element.insert) == typed
            if ta != tb { return ta }
            if !keepOrder {
                let ua = memory.use(cmd, [a.element.insert, a.element.title] + a.element.also)
                let ub = memory.use(cmd, [b.element.insert, b.element.title] + b.element.also)
                if ua != ub { return ua > ub }
            }
            let za = a.element.count == 0, zb = b.element.count == 0
            if za != zb { return !za }
            if sortByCount, let ca = a.element.count, let cb = b.element.count, ca != cb { return ca > cb }
            return a.offset < b.offset
        }
        return ranked.map(\.element)
    }

    /// #path の候補: よく使う場所（記録から）→ 中のファイルが多いフォルダ（ほかの条件の中で）→ 最近使ったフォルダ。
    /// 手元の一覧も記録も無ければ決まった場所だけ
    static func placeItems(partial: String, others: QueryFilters, src: FilterSource?, memory: FilterMemory, now: Date) -> [Item] {
        let top = src?.topFolders(within: others, limit: 40)
        var byPath: [String: Int] = [:]
        for (p, c) in top ?? [] { byPath[p] = c }
        var cands: [(String, Bool)] = memory.folders.prefix(8).map { ($0, true) }   // (場所, よく使う)
        cands += (top ?? []).map { ($0.0, false) }
        cands += (src?.recentFolders(limit: 6) ?? []).map { ($0, false) }
        if cands.isEmpty { cands = fallbackPlaces.map { (($0 as NSString).expandingTildeInPath, false) } }
        let n = Describe.normalize(partial)
        var seen = Set<String>(), out: [Item] = []
        for (p, fav) in cands where seen.insert(p).inserted {
            let short = p.hasPrefix("/") ? (p as NSString).abbreviatingWithTildeInPath : p
            let last = (p as NSString).lastPathComponent
            guard n.isEmpty || Describe.normalize(last).hasPrefix(n) || Describe.normalize(short).contains(n) else { continue }
            out.append(Item(title: last, detail: short, symbol: fav ? "star" : "folder", insert: quoted(short),
                            count: byPath[p], also: [last], badge: fav ? "よく使う" : ""))
            if out.count >= 8 { break }
        }
        // 件数の分からない場所（よく使う場所・最近のフォルダ）は数える口に聞く
        let missing = out.filter { $0.count == nil }.map(\.insert)
        if let src, !missing.isEmpty, let got = src.counts(.path, values: missing.map(QueryFilters.unquote), within: others, now: now) {
            out = out.map { it in var x = it; if x.count == nil { x.count = got[QueryFilters.unquote(it.insert)] }; return x }
        }
        return out
    }

    /// #with・#near の候補: 最近選んだファイル（記録から）と、数える口の「最近使った物」。名前の一部で絞る。件数は出さない
    static func fileItems(partial: String, src: FilterSource?, memory: FilterMemory) -> [Item] {
        let n = Describe.normalize(partial)
        var seen = Set<String>(), out: [Item] = []
        let fm = FileManager.default
        for p in memory.files.prefix(30) + (src?.recentFiles(limit: 30) ?? []) where seen.insert(p).inserted {
            let name = (p as NSString).lastPathComponent
            let short = (p as NSString).abbreviatingWithTildeInPath
            guard n.isEmpty || Describe.normalize(name).contains(n) || Describe.normalize(short).contains(n) else { continue }
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: p, isDirectory: &isDir)
            let sym = isDir.boolValue ? "folder" : "doc"
            out.append(Item(title: name, detail: (short as NSString).deletingLastPathComponent, symbol: exists ? sym : "doc",
                            insert: quoted(short), also: [name]))
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
        // 打ったとおりの値が候補の先頭にあれば補わない（「11-1」に「6」を足して 11-16 にしない）
        if let f = p.items.first, Describe.normalize(f.insert) == n { return nil }
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

    /// 一覧の 1 行を決めたときの入力欄の文字と、チップにするコマンド（値まで決まったときだけ）。
    /// commits: まとめてチップにするコマンド（よく使う組み合わせ・保存した名前。commit と同時には返さない）
    public static func accept(_ item: Item, palette p: Palette, text: String) -> (text: String, commit: String?, commits: [String]) {
        let head = String(text.prefix(p.start))
        switch p.mode {
        case .commands:
            if !item.commits.isEmpty { return (tidy(head), nil, item.commits) }
            if QueryFilters.commandName(item.insert).map({ QueryFilters.saveWords.contains($0) }) == true {
                return (head + "#保存 ", nil, [])
            }
            if QueryFilters.commandName(item.insert).map({ QueryFilters.aliasWords.contains($0) }) == true {
                return (head + "#alias ", nil, [])
            }
            if QueryFilters.commandName(item.insert).map({ QueryFilters.clipWords.contains($0) }) == true {
                return (head + "#clip ", nil, [])
            }
            guard let cmd = QueryFilters.command(named: String(item.insert.dropFirst())) else { return (text, nil, []) }
            return (head + cmd.name + " ", nil, [])
        case .values(let cmd):
            return (tidy(head), cmd.name + " " + item.insert, [])
        case .alias:
            // 行き先を選ぶ状態への切り替えは入力欄の側（FilterInput.beginAlias）。ここでは「#alias 言い方」を外すだけ
            return (item.insert.isEmpty ? text : tidy(head), nil, [])
        case .save:
            // 保存は入力欄の側（FilterInput.onSave）で行う。ここでは入力欄から「#保存 名前」を外すだけ
            return (item.insert.isEmpty ? text : tidy(head), nil, [])
        }
    }

    static func tidy(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "" : t + " "
    }

    /// 打ち終えたコマンド（空白まで打った「#date 2026-11-14 」）を入力欄から抜き出してチップにする。
    /// 最後が空白でなければ何もしない（打ちかけを消さない）。読めない値のコマンドは残す（入力欄の下に知らせる）。
    /// 保存した名前（「#仕事のPDF 」）は中身のコマンドに広げてチップにする
    public static func extractCommitted(_ text: String, now: Date = Date()) -> (commands: [String], text: String)? {
        guard text.last?.isWhitespace == true else { return nil }
        let raw = QueryFilters.tokenize(text)
        // 「#保存 …」の後ろは保存の名前なので触らない
        if raw.contains(where: { QueryFilters.commandName($0).map { (QueryFilters.saveWords + QueryFilters.aliasWords).contains($0) } ?? false }) {
            return nil
        }
        let toks = QueryFilters.expandShorthands(raw)
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

    /// 値まで決まった後に、次に付けそうなコマンド（insert は「#date today」のようにコマンドと値の組）。件数 0 は出さない。
    /// よく使う組み合わせの続き（#ext pdf の後の #path Downloads）があれば先頭に
    public static func next(_ f: QueryFilters, context src: FilterSource?, memory: FilterMemory = .empty, now: Date = Date()) -> [Item] {
        guard f.isActive, !f.wantsApps else { return [] }
        var out: [Item] = []
        let have = Set(f.parsed.compactMap(FilterMemory.canonical).map(Describe.normalize))
        for c in memory.combos {
            let normed = c.commands.map(Describe.normalize)
            guard !have.isEmpty, have.isSubset(of: Set(normed)) else { continue }
            let rest = c.commands.filter { !have.contains(Describe.normalize($0)) }
            if rest.isEmpty || rest.contains(where: { QueryFilters.parse($0).order.first.map(f.order.contains) ?? false }) { continue }
            out.append(Item(title: rest.joined(separator: " "), detail: "", symbol: "clock.arrow.circlepath", insert: rest.joined(separator: " "),
                            commits: rest, badge: "よく使う"))
            break
        }
        guard let src else { return out }
        let total = src.total(f) ?? Int.max
        guard total > 0 else { return out }
        func count(_ cmd: QueryFilters.Command, _ vs: [String]) -> [String: Int] { src.counts(cmd, values: vs, within: f, now: now) ?? [:] }
        let hasDate = !f.dates.isEmpty
        let hasKind = !f.kinds.isEmpty || !f.kindExts.isEmpty || !f.exts.isEmpty
        if !hasDate {
            let ds = [("today", "今日"), ("7d", "直近7日"), ("1m", "直近1か月")]
            let got = count(.date, ds.map(\.0))
            var n = 0
            for (v, l) in ds where n < 2 {
                if let c = got[v], c > 0 && c < total {
                    out.append(Item(title: "#date \(l)", detail: "", symbol: "clock", insert: "#date \(v)", count: c)); n += 1
                }
            }
        }
        if !hasKind {
            let kv = kindValues.filter { !["folder", "app"].contains($0.0) }
            let got = count(.kind, kv.map(\.0))
            let ks = kv.compactMap { k in got[k.0].map { (k, $0) } }.filter { $0.1 > 0 && $0.1 < total }.sorted { $0.1 > $1.1 }.prefix(2)
            for (k, c) in ks { out.append(Item(title: "#kind \(k.1)", detail: "", symbol: k.2, insert: "#kind \(k.0)", count: c)) }
        }
        if hasDate && hasKind && f.paths.isEmpty,
           let p = placeItems(partial: "", others: f, src: src, memory: .empty, now: now)
               .first(where: { ($0.count ?? 0) > 0 && ($0.count ?? 0) < total }) {
            out.append(Item(title: "#path \(p.title)", detail: "", symbol: "folder", insert: "#path \(p.insert)", count: p.count))
        }
        return Array(out.prefix(3))
    }
}
