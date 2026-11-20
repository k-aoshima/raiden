import Foundation

/// 入力欄の絞り込みコマンド（#kind ss #date 7d #path Desktop 請求書）。名前は Spotlight（kind / date / modified / created）と
/// find / fd（#type #ext #path #name）にそろえた。
/// QueryIntent（「昨日の」「PDFの」を言い方から推測して点数を上げ下げする）と違い、当てはまらない物は候補から外す確実な絞り込み。
///
///   違うコマンドどうしは「かつ」。同じコマンドを 2 回・カンマ区切りは「または」（#kind pdf,doc、#path Desktop #path Downloads）。
///   #date・#modified・#created を 2 回書いたら後の方で上書き（範囲は 11-14..11-16 で書く）。
///   アプリ（#type app / #kind app）は #kind（アプリ以外）・#ext・#date・#modified・#created・#path と一緒に使えない（知らせる）。
///   コマンドを抜いた残りの文がふつうの曖昧検索。残りが空なら絞り込んだ物を新しい順に並べる。
///   知らないコマンドや読めない値は絞り込まずに notes に「#size は使えません」のように残す。
///   打っている途中（「#」だけ、「#date」で値がまだ無い、最後の値が打ちかけ）は絞り込みも知らせもしない（pending）。
///   コマンドと読むのは、入力の先頭か空白の直後の「#」「＃」＋文字だけ（「C#」「#1」は普通の文字）。
public struct QueryFilters: Sendable {
    public enum Command: String, Sendable, CaseIterable {
        case kind, type, ext, date, modified, created, path, name, with, near
        public var takesValue: Bool { true }
        public var name: String { QueryFilters.mark + rawValue }
        /// 短い別名（find / fd と同じ 1 文字）。#date は無し
        public var short: String? {
            switch self {
            case .kind: return "#k"
            case .type: return "#t"
            case .ext: return "#e"
            case .modified: return "#m"
            case .created: return "#c"
            case .path: return "#p"
            case .name: return "#n"
            case .with: return "#w"
            case .near: return "#nr"
            case .date: return nil
            }
        }
        var isDate: Bool { self == .date || self == .modified || self == .created }
    }

    /// 1 つのコマンドの読み取り結果（検索の記録に残す用）
    public struct Parsed: Sendable {
        public let command: Command?   // nil は知らないコマンド
        public let raw: String         // 書かれたとおり（#date 7d）
        public let value: String?
        public let meaning: String?    // どう解釈したか（直近7日、PDF・Word）。読めなければ nil
        public let ok: Bool
    }

    public struct Chip: Sendable, Equatable {
        public let command: Command
        public let symbol: String      // SF Symbols の名前
        public let label: String       // 期間: 直近7日
    }

    public struct DateCond: Sendable {
        public let range: ClosedRange<Int>   // unix 秒
        public let label: String
    }

    public var text = ""                  // コマンドを抜いた残り（ふつうの曖昧検索に使う）
    public var hasSyntax = false          // コマンドが 1 つでも書かれていた（無ければ今までの検索そのまま）
    public var parsed: [Parsed] = []
    public var notes: [String] = []       // 「#size は使えません」など
    /// 値がまだ無い・打ちかけのコマンド（"" は「#」だけ）。絞り込みには使わない
    public var pending: String?
    /// 「#保存 名前」の名前（打ちかけも）。nil は保存の書き方ではない
    public var saving: String?
    /// 「#alias 言い方」の言い方（打ちかけも）。nil は辞書に足す書き方ではない
    public var aliasing: String?
    public var dates: [Command: DateCond] = [:]
    public var types: Set<String> = []    // f / d / app
    public var kinds: Set<String> = []    // FileCatalog.families の名前（folder・app も）
    public var kindExts: Set<String> = [] // #kind md / txt（拡張子で見る種類）
    public var exts: Set<String> = []
    public var paths: [String] = []
    public var names: [String] = []       // Describe.normalize 済み
    /// #with（一緒に使った物）・#near（同じプロジェクトの物）の基準のファイル・フォルダ。~ を広げた絶対パス（NFC）か、
    /// ~ / で始まらない値は書かれたとおり（名前）。値は 1 つで、2 回書いたら後の方。
    /// matches では見ない（実行は検索の土台の担当。Spotlight に問い合わせて絞る）
    public var withPath: String?
    public var nearPath: String?
    var labels: [Command: [String]] = [:]
    /// チップの並び（付けた順。同じコマンドは 1 つにまとめる）
    public private(set) var order: [Command] = []

    var hasKind: Bool { !kinds.isEmpty || !kindExts.isEmpty }
    /// 絞り込みが効いているか
    public var isActive: Bool {
        !types.isEmpty || hasKind || !exts.isEmpty || !dates.isEmpty || !paths.isEmpty || !names.isEmpty || hasRelation
    }
    /// #with か #near が付いている（手元の matches では絞れず、土台の側で絞る条件）
    public var hasRelation: Bool { withPath != nil || nearPath != nil }
    /// アプリを頼んだか（#type app / #kind app）
    public var wantsApps: Bool { types.contains("app") || kinds.contains("app") }
    /// アプリを候補に出すか（ファイルにしか効かない条件が付いていれば出さない）
    public var allowsApps: Bool {
        (types.isEmpty || types.contains("app")) && (!hasKind || kinds.contains("app"))
            && exts.isEmpty && dates.isEmpty && paths.isEmpty && !hasRelation
    }
    /// ファイル・フォルダを候補に出すか（アプリだけを頼んだときは出さない）
    public var allowsFiles: Bool {
        !(!types.isEmpty && types == ["app"]) && !(!kinds.isEmpty && kinds == ["app"] && kindExts.isEmpty)
    }

    // MARK: - 名前

    /// コマンドの名前と別名（一覧の絞り込みでも使う）
    public static let aliases: [(String, Command)] = [
        ("kind", .kind), ("k", .kind), ("種類", .kind),
        ("type", .type), ("t", .type), ("タイプ", .type),
        ("ext", .ext), ("e", .ext), ("拡張子", .ext),
        ("date", .date), ("日付", .date), ("期間", .date),
        ("modified", .modified), ("m", .modified), ("変更日", .modified), ("更新日", .modified),
        ("created", .created), ("c", .created), ("作成日", .created),
        ("path", .path), ("p", .path), ("in", .path), ("場所", .path),
        ("name", .name), ("n", .name), ("名前", .name),
        ("with", .with), ("w", .with), ("一緒", .with),
        ("near", .near), ("nr", .near), ("近く", .near),
    ]

    /// 今の条件に名前を付けて保存するときの書き方（#保存 仕事のPDF）。絞り込みには使わず、入力欄が受け取る
    public static let saveWords = ["save", "保存"]
    /// 辞書に足すときの書き方（#alias 黒い画面）。絞り込みには使わず、入力欄が受け取る
    public static let aliasWords = ["alias", "dict", "辞書"]

    /// #type の別名（前の版の名前）。#app → #type app、#folder → #type d、#file → #type f。
    /// 「#t #app」のように #type の値の位置に来たら値として読む
    public static let typeShorthands: [(String, String)] = [("app", "app"), ("folder", "d"), ("file", "f")]

    static func shorthand(_ token: String) -> String? {
        guard let n = commandName(token) else { return nil }
        return typeShorthands.first { $0.0 == n }?.1
    }

    /// 打ちかけの別名（「#ap」「#fol」）か
    static func isShorthandPrefix(_ name: String) -> Bool {
        !name.isEmpty && typeShorthands.contains { $0.0.hasPrefix(name) }
    }

    /// トークンの別名を #type の形に直す（#app → #type app、#t #app → #t app）
    public static func expandShorthands(_ toks: [String]) -> [String] {
        var out: [String] = []
        for t in toks {
            if let n = commandName(t), !n.isEmpty, command(named: n) == nil, let sf = SavedFilters.find(n) {
                out += sf.commands.flatMap { tokenize($0) }
                continue
            }
            if let v = shorthand(t) {
                if let p = out.last, let pn = commandName(p), command(named: pn) == .type { out.append(v) } else { out += ["#type", v] }
            } else { out.append(t) }
        }
        return out
    }

    public static func command(named n: String) -> Command? {
        let k = Describe.normalize(n)
        return aliases.first { Describe.normalize($0.0) == k }?.1
    }

    /// 種類の値（Spotlight の kind と同じ言い方＋短い形）→ families（FileCatalog.families と同じ名前）
    static let kindWords: [(String, String)] = [
        ("pdf", "pdf"),
        ("image", "image"), ("img", "image"), ("画像", "image"), ("写真", "image"), ("photo", "image"), ("picture", "image"),
        ("screenshot", "screenshot"), ("ss", "screenshot"), ("スクショ", "screenshot"), ("スクリーンショット", "screenshot"),
        ("movie", "movie"), ("video", "movie"), ("動画", "movie"),
        ("music", "audio"), ("audio", "audio"), ("音声", "audio"), ("音楽", "audio"),
        ("document", "doc"), ("doc", "doc"), ("docs", "doc"), ("word", "doc"), ("文書", "doc"), ("ワード", "doc"),
        ("spreadsheet", "sheet"), ("xls", "sheet"), ("sheet", "sheet"), ("excel", "sheet"), ("表計算", "sheet"), ("エクセル", "sheet"),
        ("presentation", "slide"), ("ppt", "slide"), ("slide", "slide"), ("slides", "slide"), ("スライド", "slide"),
        ("text", "text"), ("テキスト", "text"),
        ("code", "code"), ("コード", "code"),
        ("archive", "archive"), ("zip", "archive"), ("圧縮", "archive"),
        ("3d", "3d"), ("font", "font"), ("フォント", "font"), ("web", "web"), ("design", "design"), ("デザイン", "design"),
        ("folder", "folder"), ("フォルダ", "folder"), ("app", "app"), ("application", "app"), ("アプリ", "app"),
    ]
    static let kindExtWords: [String: [String]] = ["md": ["md", "markdown"], "markdown": ["md", "markdown"], "txt": ["txt"]]

    static let familyLabel: [String: String] = [
        "pdf": "PDF", "image": "画像", "screenshot": "スクショ", "movie": "動画", "audio": "音声", "doc": "Word・文書",
        "sheet": "Excel・表計算", "slide": "スライド", "text": "テキスト", "code": "コード", "archive": "圧縮", "3d": "3D",
        "font": "フォント", "web": "Web", "design": "デザイン", "folder": "フォルダ", "app": "アプリ",
    ]

    static let typeWords: [String: String] = [
        "f": "f", "file": "f", "ファイル": "f", "d": "d", "dir": "d", "directory": "d", "folder": "d", "フォルダ": "d",
        "app": "app", "application": "app", "アプリ": "app",
    ]
    static let typeLabel: [String: String] = ["f": "ファイル", "d": "フォルダ", "app": "アプリ"]

    // MARK: - 読み取り

    /// 空白で区切る。「"」で始まる値は次の「"」まで 1 つ（#path "Obsidian Vault"）
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false
        for ch in s {
            if ch == "\"" || ch == "”" || ch == "“" {
                if quoted { quoted = false; cur.append("\""); continue }
                if cur.isEmpty { quoted = true; cur.append("\""); continue }
            }
            if !quoted && ch.isWhitespace {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func unquote(_ s: String) -> String {
        var t = s
        if t.hasPrefix("\"") { t.removeFirst() }
        if t.hasSuffix("\"") { t.removeLast() }
        return t
    }

    /// コマンドの始まりの記号。全角の「＃」も同じに扱う（日本語入力のまま打てるように）
    public static let mark = "#"
    static func isMark(_ c: Character) -> Bool { c == "#" || c == "＃" }

    /// トークンがコマンドの形か。トークンの先頭の「#」「＃」＋文字（「#1」は数字なので違う。「C#」は途中なので違う）。
    /// 返り値は名前（「#」だけなら ""）
    public static func commandName(_ token: String) -> String? {
        guard let first = token.first, isMark(first) else { return nil }
        let n = String(token.dropFirst())
        if n.isEmpty { return "" }
        guard let f = n.first, f.isLetter, !n.contains("/"), !n.contains("-"), !n.contains(".") else { return nil }
        return n.lowercased()
    }

    public static func parse(_ query: String, now: Date = Date()) -> QueryFilters {
        var f = QueryFilters()
        let toks = expandShorthands(tokenize(query))
        let trailingSpace = query.last?.isWhitespace ?? false
        var rest: [String] = []
        var i = 0
        while i < toks.count {
            let t = toks[i]
            guard let name = commandName(t) else { rest.append(t); i += 1; continue }
            f.hasSyntax = true
            let isLast = i == toks.count - 1
            if name.isEmpty { if isLast && !trailingSpace { f.pending = "" }; i += 1; continue }
            // #保存 名前: 後ろは全部、保存する名前（入力欄が扱う）
            if saveWords.contains(name) { f.pending = "save"; f.saving = toks[(i + 1)...].joined(separator: " "); break }
            // #alias 言い方: 後ろは全部、辞書に足す言い方
            if aliasWords.contains(name) { f.pending = "alias"; f.aliasing = toks[(i + 1)...].joined(separator: " "); break }
            // #clip: クリップボードの履歴（入力欄が受け取る。後ろは全部、履歴を探す言葉）
            if clipWords.contains(name) { f.pending = "clip"; break }
            guard let cmd = command(named: name) else {
                // 打ちかけ（「#da」）は知らせない。空白を打った後や途中にあれば知らせる
                if isLast && !trailingSpace && (aliases.contains(where: { Describe.normalize($0.0).hasPrefix(Describe.normalize(name)) })
                                                || isShorthandPrefix(name) || SavedFilters.hasPrefix(name)
                                                || (saveWords + aliasWords + clipWords).contains(where: { $0.hasPrefix(name) })) {
                    f.pending = name
                } else {
                    f.notes.append("#\(name) は使えません")
                    f.parsed.append(Parsed(command: nil, raw: t, value: nil, meaning: nil, ok: false))
                }
                i += 1; continue
            }
            // 値: 次のトークン（コマンドの形でなければ）
            guard i + 1 < toks.count, commandName(toks[i + 1]) == nil else {
                // 「#t #ap」（#type の値の位置で別名を打ちかけ）は待つ
                if cmd == .type, i + 2 == toks.count, !trailingSpace, let n = commandName(toks[i + 1]), isShorthandPrefix(n) {
                    f.pending = cmd.rawValue
                    i += 2; continue
                }
                if isLast { f.pending = cmd.rawValue } else { f.notes.append("\(cmd.name) の後に値がありません") }
                i += 1; continue
            }
            let v = unquote(toks[i + 1])
            let valueIsLast = i + 1 == toks.count - 1 && !trailingSpace
            i += 2
            // 打ちかけの種類（#kind sc → screenshot）は拡張子として読まずに待つ
            if valueIsLast && cmd == .kind, let lastPiece = pieces(v).last,
               !kindWords.contains(where: { Describe.normalize($0.0) == lastPiece }),
               kindWords.contains(where: { Describe.normalize($0.0).hasPrefix(lastPiece) }) {
                f.pending = cmd.rawValue
                continue
            }
            if let meaning = f.apply(cmd, v, now: now) {
                f.parsed.append(Parsed(command: cmd, raw: t + " " + toks[i - 1], value: v, meaning: meaning, ok: true))
            } else if valueIsLast {
                f.pending = cmd.rawValue   // 打ちかけ（#date 2026-1）は知らせない
            } else {
                f.notes.append("\(cmd.name) の「\(v)」は読めません")
                f.parsed.append(Parsed(command: cmd, raw: t + " " + toks[i - 1], value: v, meaning: nil, ok: false))
            }
        }
        // アプリはファイルにしか効かない条件と一緒に使えない
        if f.wantsApps {
            var others: [String] = []
            if f.kinds.subtracting(["app"]).count > 0 || !f.kindExts.isEmpty { others.append("#kind") }
            if !f.exts.isEmpty { others.append("#ext") }
            for c in [Command.date, .modified, .created] where f.dates[c] != nil { others.append(c.name) }
            if !f.paths.isEmpty { others.append("#path") }
            if f.withPath != nil { others.append("#with") }
            if f.nearPath != nil { others.append("#near") }
            if !others.isEmpty { f.notes.append("アプリ（#type app）と \(others.joined(separator: "・")) は一緒に使えません") }
        }
        f.text = f.hasSyntax ? rest.joined(separator: " ") : query.trimmingCharacters(in: .whitespacesAndNewlines)
        return f
    }

    private mutating func remember(_ c: Command, _ ls: [String], replace: Bool = false) {
        if !order.contains(c) { order.append(c) }
        if replace { labels[c] = ls; return }
        for l in ls where !(labels[c] ?? []).contains(l) { labels[c, default: []].append(l) }
    }

    static func pieces(_ v: String) -> [String] {
        v.split(whereSeparator: { $0 == "," || $0 == "、" || $0 == "，" })
            .map { Describe.normalize(String($0)).trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            .filter { !$0.isEmpty }
    }

    /// 値を読んで条件に足す。読めたら意味（チップの文字）を、読めなければ nil を返す（読めなければ何も足さない）
    public mutating func apply(_ cmd: Command, _ v: String, now: Date) -> String? {
        switch cmd {
        case .date, .modified, .created:
            guard let (r, l) = Self.parseDate(v, now: now) else { return nil }
            dates[cmd] = DateCond(range: r, label: l)   // 2 回目は上書き
            remember(cmd, [l], replace: true)
            return l
        case .kind:
            var fams: [String] = [], xs: [String] = [], ls: [String] = []
            for p in Self.pieces(v) {
                if let e = Self.kindExtWords[p] { xs += e; ls.append(p == "txt" ? "テキスト(.txt)" : "Markdown"); continue }
                if let fam = Self.kindWords.first(where: { Describe.normalize($0.0) == p })?.1 {
                    fams.append(fam); ls.append(Self.familyLabel[fam] ?? p); continue
                }
                // 種類の名前でなければ拡張子として読む（#kind pdf,docx。#ext と違い、同じ #kind の中の「または」）
                guard p.count <= 10, p.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
                xs.append(p); ls.append("." + p)
            }
            if fams.isEmpty && xs.isEmpty { return nil }
            kinds.formUnion(fams); kindExts.formUnion(xs)
            remember(.kind, ls)
            return ls.joined(separator: "・")
        case .type:
            let ts = Self.pieces(v).map { Self.typeWords[$0] }
            guard !ts.isEmpty, !ts.contains(where: { $0 == nil }) else { return nil }
            let ls = ts.map { Self.typeLabel[$0!]! }
            types.formUnion(ts.map { $0! })
            remember(.type, ls)
            return ls.joined(separator: "・")
        case .ext:
            let xs = Self.pieces(v)
            guard !xs.isEmpty, xs.allSatisfy({ $0.count <= 10 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }) else { return nil }
            exts.formUnion(xs)
            remember(.ext, xs.map { "." + $0 })
            return xs.map { "." + $0 }.joined(separator: "・")
        case .path:
            let p = v.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { return nil }
            if !paths.contains(p) { paths.append(p) }
            remember(.path, [Self.placeLabel(p)])
            return Self.placeLabel(p)
        case .name:
            let n = Describe.normalize(v)
            if n.isEmpty { return nil }
            if !names.contains(n) { names.append(n) }
            remember(.name, ["「\(v)」"])
            return "「\(v)」"
        case .with, .near:
            let p = v.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { return nil }
            let full = p.hasPrefix("~") || p.hasPrefix("/")
                ? (p as NSString).expandingTildeInPath.precomposedStringWithCanonicalMapping : p.precomposedStringWithCanonicalMapping
            if cmd == .with { withPath = full } else { nearPath = full }
            let l = (full as NSString).lastPathComponent
            remember(cmd, [l], replace: true)
            return l
        }
    }

    /// そのコマンドの条件だけを外した物（値の候補の件数を「ほかの条件の中で」数える用）
    public func without(_ c: Command) -> QueryFilters {
        var f = self
        switch c {
        case .date, .modified, .created: f.dates[c] = nil
        case .kind: f.kinds = []; f.kindExts = []
        case .type: f.types = []
        case .ext: f.exts = []
        case .path: f.paths = []
        case .name: f.names = []
        case .with: f.withPath = nil
        case .near: f.nearPath = nil
        }
        f.labels[c] = nil
        f.order.removeAll { $0 == c }
        return f
    }

    static func placeLabel(_ p: String) -> String {
        p.hasPrefix("/") ? (p as NSString).abbreviatingWithTildeInPath : p
    }

    // MARK: - 当てはまるか

    /// ファイルごとに前もって作っておく文字（数千件を 1 文字ごとに数え直すときの正規化を省く）
    public struct FileKeys: Sendable {
        public let ext: String
        public let name: String        // Describe.normalize した名前
        public let parent: String      // Describe.normalize したホームからの親フォルダのパス（documents/仕事）
        public init(_ e: FileEntry) {
            ext = (e.name as NSString).pathExtension.lowercased()
            name = Describe.normalize(e.name)
            parent = Describe.normalize(QueryFilters.relParent(e.path))
        }
    }

    static func relParent(_ path: String) -> String {
        let home = NSHomeDirectory()
        let parent = (path as NSString).deletingLastPathComponent
        return parent.hasPrefix(home + "/") ? String(parent.dropFirst(home.count + 1)) : (parent == home ? "" : parent)
    }

    /// ファイル・フォルダが条件に当てはまるか（候補の絞り込みも、値の候補の件数も、この関数で数える）。
    /// #with・#near は見ない（手元の一覧では決められない。土台の側で絞る）
    public func matches(_ e: FileEntry, keys k0: FileKeys? = nil) -> Bool {
        if !types.isEmpty && !types.contains(e.isDir ? "d" : "f") { return false }
        let k = k0 ?? FileKeys(e)
        if hasKind {
            if e.isDir {
                if !kinds.contains("folder") { return false }
            } else if kinds.isDisjoint(with: e.families) && !kindExts.contains(k.ext) { return false }
        }
        if !exts.isEmpty && (e.isDir || !exts.contains(k.ext)) { return false }
        for (cmd, d) in dates {
            let ts: [Int]
            switch cmd {
            case .modified: ts = [e.mtime]
            case .created: ts = [e.created]
            default: ts = [e.lastUsed, e.mtime, e.added, e.created]   // 使った日・変更日・追加日・作成日のどれか
            }
            if !ts.contains(where: { $0 > 0 && d.range.contains($0) }) { return false }
        }
        if !paths.isEmpty && !paths.contains(where: { Self.isUnder(e.path, $0, parentKey: k.parent) }) { return false }
        if !names.isEmpty && !names.contains(where: { k.name.contains($0) }) { return false }
        return true
    }

    /// アプリが条件に当てはまるか（アプリに効くのは #name だけ）
    public func matches(app a: AppEntry) -> Bool {
        guard allowsApps else { return false }
        if names.isEmpty { return true }
        let ns = [a.jp, a.name, ((a.path as NSString).lastPathComponent as NSString).deletingPathExtension].map(Describe.normalize)
        return names.contains { n in ns.contains { $0.contains(n) } }
    }

    /// path が場所 p の下か。「~/Desktop」「/Users/..」はその下。名前なら、ホームからの親フォルダのどれかの名前に含まれれば当たり。
    /// 「Documents/仕事」のように「/」を含む名前は、親フォルダまでのパスの一部に含まれれば当たり（find #path と同じ考え）
    public static func isUnder(_ path: String, _ p: String, parentKey: String? = nil) -> Bool {
        if p.hasPrefix("~") || p.hasPrefix("/") {
            var base = (p as NSString).expandingTildeInPath.precomposedStringWithCanonicalMapping
            while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
            return path.hasPrefix(base + "/")
        }
        let rel = parentKey ?? Describe.normalize(relParent(path))
        let needle = Describe.normalize(p)
        if needle.isEmpty { return false }
        if needle.contains("/") { return rel.contains(needle) }
        return rel.split(separator: "/").contains { $0.contains(needle) }
    }

    // MARK: - チップ

    public var chips: [Chip] {
        order.compactMap { c in
            guard let ls = labels[c], !ls.isEmpty else { return nil }
            let v = ls.joined(separator: "・")
            switch c {
            case .date: return Chip(command: c, symbol: "clock", label: "期間: " + v)
            case .modified: return Chip(command: c, symbol: "pencil", label: "変更日: " + v)
            case .created: return Chip(command: c, symbol: "calendar", label: "作成日: " + v)
            case .kind: return Chip(command: c, symbol: "doc", label: "種類: " + v)
            case .type:
                let s = types == ["d"] ? "folder" : types == ["app"] ? "app" : types == ["f"] ? "doc" : "square.grid.2x2"
                return Chip(command: c, symbol: s, label: v + "だけ")
            case .ext: return Chip(command: c, symbol: "tag", label: "拡張子: " + v)
            case .path: return Chip(command: c, symbol: "folder", label: "場所: " + v)
            case .name: return Chip(command: c, symbol: "textformat", label: "名前: " + v)
            case .with: return Chip(command: c, symbol: "link", label: "一緒に使った: " + v)
            case .near: return Chip(command: c, symbol: "point.3.connected.trianglepath.dotted", label: "同じプロジェクト: " + v)
            }
        }
    }

    // MARK: - 期間

    /// today / yesterday / 7d / 2w / 3m / 1y / 2026 / 2026-11 / 2026-11-14 / 11-14 / a..b / 今日・昨日・今週・先週・今月・先月・今年・去年
    public static func parseDate(_ v0: String, now: Date) -> (ClosedRange<Int>, String)? {
        let v = Describe.normalize(v0).replacingOccurrences(of: "〜", with: "..").replacingOccurrences(of: "~", with: "..")
        if let r = v.range(of: "..") {
            let a = String(v[..<r.lowerBound]), b = String(v[r.upperBound...])
            let ra = a.isEmpty ? nil : single(a, now: now), rb = b.isEmpty ? nil : single(b, now: now)
            if (!a.isEmpty && ra == nil) || (!b.isEmpty && rb == nil) || (ra == nil && rb == nil) { return nil }
            var lo = ra?.0.lowerBound ?? Int.min, hi = rb?.0.upperBound ?? Int.max
            if let ra, let rb, rb.0.upperBound < ra.0.lowerBound { lo = rb.0.lowerBound; hi = ra.0.upperBound }
            return (lo...hi, "\(ra?.1 ?? "")〜\(rb?.1 ?? "")")
        }
        return single(v, now: now)
    }

    static func single(_ v: String, now: Date) -> (ClosedRange<Int>, String)? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: today)! }
        func r(_ a: Date, _ b: Date) -> ClosedRange<Int> { Int(a.timeIntervalSince1970)...Int(b.timeIntervalSince1970) - 1 }
        let week = cal.dateInterval(of: .weekOfYear, for: now)!
        let month = cal.dateInterval(of: .month, for: now)!
        let year = cal.dateInterval(of: .year, for: now)!
        let words: [([String], ClosedRange<Int>, String)] = [
            (["today", "今日", "きょう"], r(today, day(1)), "今日"),
            (["yesterday", "昨日", "きのう"], r(day(-1), today), "昨日"),
            (["おととい", "一昨日"], r(day(-2), day(-1)), "おととい"),
            (["thisweek", "今週"], r(week.start, week.end), "今週"),
            (["lastweek", "先週"], r(cal.date(byAdding: .day, value: -7, to: week.start)!, week.start), "先週"),
            (["thismonth", "今月"], r(month.start, month.end), "今月"),
            (["lastmonth", "先月"], r(cal.date(byAdding: .month, value: -1, to: month.start)!, month.start), "先月"),
            (["thisyear", "今年"], r(year.start, year.end), "今年"),
            (["lastyear", "去年", "昨年"], r(cal.date(byAdding: .year, value: -1, to: year.start)!, year.start), "去年"),
        ]
        for (ws, rg, l) in words where ws.contains(v) { return (rg, l) }
        func m(_ pat: String) -> [Int]? {
            guard let re = try? NSRegularExpression(pattern: "^" + pat + "$"),
                  let mt = re.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)) else { return nil }
            return (1..<mt.numberOfRanges).compactMap { Range(mt.range(at: $0), in: v).flatMap { Int(v[$0]) } }
        }
        // 直近 N 日・週・か月・年（QueryIntent の「直近N日」と同じく、N 日前の 0 時から今日の終わりまで）
        if let re = try? NSRegularExpression(pattern: "^([0-9]+)(d|w|m|y|日|週|週間|か月|ヶ月|カ月|ヵ月|月|年)$"),
           let mt = re.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)),
           let nr = Range(mt.range(at: 1), in: v), let ur = Range(mt.range(at: 2), in: v), let n = Int(v[nr]), n > 0, n <= 100 {
            let u = String(v[ur])
            let (start, label): (Date, String)
            switch u {
            case "d", "日": (start, label) = (day(-n), "直近\(n)日")
            case "w", "週", "週間": (start, label) = (day(-7 * n), "直近\(n)週間")
            case "y", "年": (start, label) = (cal.date(byAdding: .year, value: -n, to: today)!, "直近\(n)年")
            default: (start, label) = (cal.date(byAdding: .month, value: -n, to: today)!, "直近\(n)か月")
            }
            return (r(start, day(1)), label)
        }
        func ymd(_ y: Int, _ mo: Int, _ d: Int) -> Date? {
            guard (1...12).contains(mo), let dt = cal.date(from: DateComponents(year: y, month: mo, day: d)),
                  cal.component(.month, from: dt) == mo, cal.component(.day, from: dt) == d else { return nil }
            return dt
        }
        let sep = "[-/.]"
        if let x = m("(20[0-9]{2})"), x.count == 1, let a = ymd(x[0], 1, 1) {
            return (r(a, cal.date(byAdding: .year, value: 1, to: a)!), "\(x[0])年")
        }
        if let x = m("(20[0-9]{2})" + sep + "([0-9]{1,2})"), x.count == 2, let a = ymd(x[0], x[1], 1) {
            return (r(a, cal.date(byAdding: .month, value: 1, to: a)!), "\(x[0])年\(x[1])月")
        }
        if let x = m("(20[0-9]{2})" + sep + "([0-9]{1,2})" + sep + "([0-9]{1,2})"), x.count == 3, let a = ymd(x[0], x[1], x[2]) {
            return (r(a, cal.date(byAdding: .day, value: 1, to: a)!), "\(x[0])/\(x[1])/\(x[2])")
        }
        // 月-日（今年。まだ来ていない日なら去年）
        if let x = m("([0-9]{1,2})" + sep + "([0-9]{1,2})"), x.count == 2 {
            var y = cal.component(.year, from: now)
            guard var a = ymd(y, x[0], x[1]) else { return nil }
            if a > now { y -= 1; guard let b = ymd(y, x[0], x[1]) else { return nil }; a = b }
            return (r(a, cal.date(byAdding: .day, value: 1, to: a)!), "\(x[0])/\(x[1])")
        }
        return nil
    }
}

public extension FileEntry {
    /// 見本・確かめ用（実際の一覧は FileCatalog.collect で作る）
    init(path: String, isDir: Bool = false, families: [String] = [], mtime: Int = 0, created: Int = 0, added: Int = 0, lastUsed: Int = 0) {
        let name = (path as NSString).lastPathComponent
        self.init(path: path, name: name, parentName: ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent,
                  isDir: isDir, kind: "", families: families.isEmpty ? FileCatalog.families(name: name, isDir: isDir) : families,
                  size: 0, mtime: mtime, created: created, added: added, lastUsed: lastUsed, usedDays: [], downloaded: false)
    }
}
