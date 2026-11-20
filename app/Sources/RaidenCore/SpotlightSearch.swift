import CoreServices
import Foundation

/// ファイル・フォルダの検索は Spotlight（MDQuery）に問い合わせる（Raiden は自前の一覧もベクトルも持たない）。
///
/// 入力欄の「#」（QueryFilters）と残りの言葉を Spotlight の条件に置き換え、結果を Raiden の側で並べる。
///   名前の言葉   kMDItemDisplayName / kMDItemFSName の部分一致（"*言葉*"cd。大文字小文字・濁点を区別しない）。日本語はひらがなの所で区切る（words）。
///               言葉どうしは「または」で引き、当たった言葉の割合で並べる（全部に当たる物が先）
///   #name       同じ部分一致。値どうしは「または」
///   #kind       kMDItemContentTypeTree（種類ごとの UTI）か、kMDItemFSName の末尾（拡張子）
///   #ext        kMDItemFSName の末尾（"*.pdf"c）
///   #type       kMDItemContentType == public.folder か、その否定
///   #date       kMDItemLastUsedDate・kMDItemContentModificationDate・kMDItemDateAdded・kMDItemContentCreationDate のどれかが範囲に入る物を問い合わせ、
///               結果は一番新しい日が範囲に入る物だけ残す（QueryFilters.dateHit。昨日作って今日上書きした物は「今日」）
///   #modified   kMDItemContentModificationDate、#created は kMDItemContentCreationDate
///   #path       「~/」「/」で始まればそこを検索の範囲（searchScopes）に。名前なら、名前にそれを含むフォルダを Spotlight で引いて範囲にする
///   #with X     X の kMDItemLastUsedDate の前後 withWindow 秒に使った物。Raiden から開いた記録の co_used の線の重みで加点し、X 自身は外す
///   #near X     X から親をさかのぼって見つけたプロジェクトの根（projectRoot）を範囲にする
/// 「#」の無い入力は QueryIntent（「先週の」「PDFの」）の時間・種類をそれぞれ #date・#kind と同じ条件にし、残りを名前の言葉にする。
/// 「A と同じ日の B」は #with A と B、「A の中の B」は #path A と B として引く。
///
/// Spotlight は条件を細かくは表せない所がある（#path の名前の部分・パッケージの中・除外）。そこは結果を QueryFilters.matches と
/// 除外の設定で Raiden の側でもう一度ふるう。
///
/// 並べ方: 名前の一致の強さ（先頭・単語の先頭 0.6、途中 0.35、当たらない言葉 0。言葉ごとの平均）＋使った日・変えた日の新しさ（最大 0.2、30 日で 1/e）
///   ＋「選んだ」の記録（入力 → ファイルの例。入力の文字の 2 文字の組の重なりで 0.5 まで）＋ #with の co_used の線の重み（0.3 まで）。
/// 打つたびに前の問い合わせを止める（cancel）。1 回の時間は lastMs。
public final class SpotlightSearch: @unchecked Sendable {
    /// #with の前後の幅（秒）
    public static let withWindow = 30 * 60
    /// 1 回の問い合わせで受け取る件数の上限（並べる前）。名前の言葉があるときはこれで十分に絞れている
    public static let fetchLimit = 3000

    /// 除外（設定の「除外」。フォルダと名前）
    public var exclude: ScanScope
    /// 「選んだ」の記録（入力文, パス, 回数）を返す（Store.fileExamples）
    public var examples: () -> [(String, String, Float)] = { [] }
    /// path と co_used の線でつながった物（パス → 重み）を返す（Store.coUsed）
    public var coUsed: (String) -> [String: Float] = { _ in [:] }

    private let lock = NSLock()
    private var current: MDQuery?
    private var generation = 0
    public private(set) var lastMs: Double = 0
    public private(set) var lastQuery = ""

    public init(exclude: ScanScope = ScanScope(roots: [])) { self.exclude = exclude }

    /// 走っている問い合わせを止める（次の文字が来たとき）
    public func cancel() {
        lock.lock()
        generation += 1
        if let q = current { MDQueryStop(q) }
        current = nil
        lock.unlock()
    }

    // MARK: - 条件

    /// Spotlight に渡す 1 回分の条件
    public struct Request: Sendable {
        public var words: [String] = []          // 名前の言葉（または。当たった割合で並べる）
        public var names: [String] = []          // #name（または）
        public var families: Set<String> = []    // #kind の種類（FileCatalog.families の名前）
        public var kindExts: Set<String> = []    // #kind の拡張子
        public var exts: Set<String> = []        // #ext
        public var types: Set<String> = []       // #type（f / d）
        public var dates: [(QueryFilters.Command, ClosedRange<Int>)] = []
        public var scopes: [String] = []         // 範囲（絶対パス）。空なら Mac 全域（defaultScopes）
        public var pathNames: [String] = []      // #path の名前の部分（フォルダを引いて範囲にする）
        public var withAnchor: String?
        public var nearAnchor: String?
        public var download = false              // 「ダウンロードした」（~/Downloads か kMDItemWhereFroms）
        /// 結果をふるう条件（#path の名前・パス・種類の細かい所）。名前の言葉は別に見る
        public var post: QueryFilters?
        public var isEmpty: Bool {
            words.isEmpty && names.isEmpty && families.isEmpty && kindExts.isEmpty && exts.isEmpty && types.isEmpty && dates.isEmpty
                && scopes.isEmpty && pathNames.isEmpty && withAnchor == nil && nearAnchor == nil && !download
        }
        public init() {}
    }

    /// QueryFilters（「#」の読み取り結果）から条件を作る。f.text は名前の言葉。with / near は QueryFilters の値（あれば）
    public static func request(_ f: QueryFilters, now: Date = Date()) -> Request {
        var r = Request()
        r.words = words(f.text)
        r.names = f.names
        r.families = f.kinds.subtracting(["app"])
        r.kindExts = f.kindExts
        r.exts = f.exts
        r.types = f.types.subtracting(["app"])
        r.dates = f.dates.map { ($0.key, $0.value.range) }.sorted { $0.0.rawValue < $1.0.rawValue }
        for p in f.paths {
            if p.hasPrefix("~") || p.hasPrefix("/") { r.scopes.append(ScanScope.norm(p)) } else { r.pathNames.append(p) }
        }
        r.withAnchor = f.withPath
        r.nearAnchor = f.nearPath
        r.post = f
        return r
    }

    /// 「#」の無い入力: 時間・種類の言葉（QueryIntent）を条件にし、残りを名前の言葉にする
    public static func request(text q: String, now: Date = Date()) -> Request {
        let it = QueryIntent.parse(q, now: now)
        var r = Request()
        if it.hasRelation {
            if it.inside { r.pathNames = [it.anchor] } else { r.withAnchor = it.anchor }
            r.words = words(it.target)
        } else {
            r.words = words(it.isEmpty ? q : it.rest)
        }
        let fam = it.families
        if fam == ["folder"] { r.types = ["d"] } else { r.families = fam.subtracting(["folder"]) }
        if let rg = it.range { r.dates = [(.date, rg)] }
        r.download = it.download
        return r
    }

    /// 名前の言葉。空白で区切り、さらにひらがなの所と、英数字とそれ以外の境目で区切る（「大阪で泊まった宿の領収書」→ 大阪・泊・宿・領収書、
    /// 「明細PDFが入ってるとこ」→ 明細・PDF）。言葉が 2 つ以上になるときは 1 文字の語と 2 文字以下の英数字を捨てる
    /// （→ 大阪・領収書）。言葉が 1 つなら、英数字 1 文字のときだけ捨てる。ひらがなだけの入力（「せいきゅう」）はそのまま 1 語
    public static func words(_ s: String) -> [String] {
        var toks: [String] = []
        for piece in s.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            // ひらがな（長音「ー」はカタカナの語の中にもあるので区切りにしない）
            func hira(_ c: Character) -> Bool { c != "ー" && Lexical.isHira(c) }
            if piece.allSatisfy(hira) { toks.append(piece); continue }
            var cur = "", curASCII = false
            for c in piece {
                if hira(c) { if !cur.isEmpty { toks.append(cur) }; cur = ""; continue }
                let a = c.isASCII
                if !cur.isEmpty && a != curASCII { toks.append(cur); cur = "" }
                cur.append(c); curASCII = a
            }
            if !cur.isEmpty { toks.append(cur) }
        }
        if toks.count == 1 { return toks[0].count < 2 && toks[0].allSatisfy(\.isASCII) ? [] : toks }
        var out: [String] = []
        for t in toks where !out.contains(t) {
            if t.count < 2 { continue }
            if t.allSatisfy(\.isASCII) && t.count <= 2 { continue }
            out.append(t)
        }
        return out
    }

    /// 種類 → Spotlight の UTI（kMDItemContentTypeTree）。拡張子は FileCatalog.extFamily からも足す
    static let familyUTIs: [String: [String]] = [
        "pdf": ["com.adobe.pdf"], "image": ["public.image"], "movie": ["public.movie"], "audio": ["public.audio"],
        "sheet": ["public.spreadsheet"], "slide": ["public.presentation"],
        "doc": ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.sec", "public.rtf"],
        "font": ["public.font"], "archive": ["public.archive", "com.apple.disk-image"], "web": ["public.html"],
        "json": ["public.json"], "3d": ["public.3d-content"], "code": ["public.source-code"], "folder": ["public.folder"],
    ]
    /// 種類ごとの拡張子（FileCatalog.extFamily の逆引き）
    static let familyExts: [String: [String]] = {
        var m: [String: [String]] = [:]
        for (x, f) in FileCatalog.extFamily { m[f, default: []].append(x) }
        return m.mapValues { $0.sorted() }
    }()

    static func esc(_ s: String) -> String {
        var o = ""
        for c in s {
            if c == "\\" || c == "\"" || c == "*" || c == "?" || c == "'" { o.append("\\") }
            o.append(c)
        }
        return o
    }

    static func nameClause(_ w: String) -> String {
        let e = esc(w)
        return "(kMDItemDisplayName == \"*\(e)*\"cd || kMDItemFSName == \"*\(e)*\"cd)"
    }

    static func extClause(_ x: String) -> String { "kMDItemFSName == \"*.\(esc(x))\"c" }

    static func iso(_ t: Int) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return "$time.iso(" + f.string(from: Date(timeIntervalSince1970: TimeInterval(t))) + ")"
    }

    static func rangeClause(_ attr: String, _ r: ClosedRange<Int>) -> String {
        "(\(attr) >= \(iso(r.lowerBound)) && \(attr) <= \(iso(r.upperBound)))"
    }

    static func dateAttrs(_ c: QueryFilters.Command) -> [String] {
        switch c {
        case .modified: return ["kMDItemContentModificationDate"]
        case .created: return ["kMDItemContentCreationDate"]
        default: return ["kMDItemLastUsedDate", "kMDItemContentModificationDate", "kMDItemDateAdded", "kMDItemContentCreationDate"]
        }
    }

    /// 種類 1 つの条件（UTI と拡張子の「または」）。スクショは画像で、名前に「スクリーンショット」「screenshot」を含む物
    static func familyClause(_ fam: String) -> String {
        if fam == "screenshot" {
            return "(kMDItemContentTypeTree == \"public.image\" && (kMDItemFSName == \"*スクリーンショット*\"cd || kMDItemFSName == \"*screenshot*\"cd))"
        }
        var parts = (familyUTIs[fam] ?? []).map { "kMDItemContentTypeTree == \"\($0)\"" }
        parts += (familyExts[fam] ?? []).map(extClause)
        if parts.isEmpty { parts = ["kMDItemFSName == \"*.\(esc(fam))\"c"] }
        return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " || ") + ")"
    }

    /// Spotlight の問い合わせの文（条件が 1 つも無ければ全部の物）。withTime は #with の X を使った時刻
    public static func queryString(_ r: Request, withTime: Int? = nil) -> String {
        var cs: [String] = []
        if !r.words.isEmpty { cs.append(or(r.words.map(nameClause))) }
        if !r.names.isEmpty { cs.append(or(r.names.map(nameClause))) }
        var kind: [String] = r.families.sorted().map(familyClause)
        kind += r.kindExts.sorted().map(extClause)
        if !kind.isEmpty { cs.append(or(kind)) }
        if !r.exts.isEmpty { cs.append(or(r.exts.sorted().map(extClause))) }
        if r.types == ["d"] { cs.append("kMDItemContentType == \"public.folder\"") }
        if r.types == ["f"] { cs.append("kMDItemContentType != \"public.folder\"") }
        for (c, rg) in r.dates {
            let attrs = dateAttrs(c)
            cs.append(or(attrs.map { rangeClause($0, rg) }))
            // #date は一番新しい日で見る（QueryFilters.dateHit）: どの日付も範囲の後ろに無い物だけ。
            // 無い属性の比較は「!」でひっくり返しても偽のままなので、「!= *」（属性が無い）を「または」で足す
            if attrs.count > 1, rg.upperBound < Int.max {
                cs.append(attrs.map { "(\($0) <= \(iso(rg.upperBound)) || \($0) != *)" }.joined(separator: " && "))
            }
        }
        if let t = withTime { cs.append(rangeClause("kMDItemLastUsedDate", (t - withWindow)...(t + withWindow))) }
        if r.download { cs.append("kMDItemWhereFroms == \"*\"") }
        if cs.isEmpty { return "kMDItemContentTypeTree == \"public.item\"" }
        return cs.joined(separator: " && ")
    }

    static func or(_ xs: [String]) -> String { xs.count == 1 ? xs[0] : "(" + xs.joined(separator: " || ") + ")" }

    // MARK: - 範囲

    static let home = NSHomeDirectory()

    /// Mac 全域の範囲: ホームの中の各フォルダ（隠し・除外を除く。~/Library は既定で除外）と /Users/Shared、外付けのボリューム。
    /// ホーム直下のファイルは範囲にできないので、検索のたびにホームの中を 1 段だけ見て足す（homeFiles）
    public func defaultScopes() -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for n in ((try? fm.contentsOfDirectory(atPath: Self.home)) ?? []).sorted() where !exclude.excludesName(n) {
            let p = Self.home + "/" + n
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &dir), dir.boolValue, !exclude.excludesPath(ScanScope.norm(p)) else { continue }
            out.append(p)
        }
        for p in ["/Users/Shared"] where fm.fileExists(atPath: p) && !exclude.excludesPath(p) { out.append(p) }
        let boot = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        for n in (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [] where n != boot && !n.hasPrefix(".") {
            let p = "/Volumes/" + n
            if !exclude.excludesPath(p) { out.append(p) }
        }
        return out
    }

    // MARK: - 結果

    public struct Result: Sendable {
        public var files: [FileResult] = []
        public var ms: Double = 0             // Spotlight の問い合わせ（全部の段の合計）
        public var fetched = 0                // Spotlight から受け取った件数（ふるう前）
        public var query = ""                 // 問い合わせの文
        public var scopes: [String] = []      // 範囲
        public var cancelled = false
        public var note: String?              // #with / #near の X が見つからなかったなど
    }

    static let attrs: [CFString] = [kMDItemPath, kMDItemFSName, kMDItemDisplayName, kMDItemContentType, kMDItemContentTypeTree,
                                    kMDItemKind, kMDItemLastUsedDate, kMDItemContentModificationDate, kMDItemContentCreationDate,
                                    "kMDItemDateAdded" as CFString, kMDItemFSSize, kMDItemWhereFroms, kMDItemFSCreationDate]

    /// MDQuery を同期で走らせ、受け取った物の属性を返す。cancel で止まったら nil
    private func run(_ text: String, scopes: [String], max: Int, gen: Int) -> [[String: Any]]? {
        // 属性は sortingAttrs に入れて問い合わせと一緒に受け取る（1 件ずつ MDItemCopyAttributes すると 2,000 件で 0.45 秒、こちらは数 ms）。
        // パスだけはこの形で返らないので 1 件ずつ読む（速い）
        guard let q = MDQueryCreate(kCFAllocatorDefault, text as CFString, nil, Self.fetchAttrs as CFArray) else { return [] }
        if !scopes.isEmpty { MDQuerySetSearchScope(q, scopes as CFArray, 0) }
        MDQuerySetMaxCount(q, max)
        lock.lock()
        if gen != generation { lock.unlock(); return nil }
        current = q
        lock.unlock()
        let ok = MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue))
        lock.lock()
        let stale = gen != generation
        if current === q { current = nil }
        lock.unlock()
        if stale { return nil }
        guard ok else { return [] }
        MDQueryDisableUpdates(q)
        var out: [[String: Any]] = []
        let n = MDQueryGetResultCount(q)
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let raw = MDQueryGetResultAtIndex(q, i) else { continue }
            let item = unsafeBitCast(raw, to: MDItem.self)
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            var d: [String: Any] = [kMDItemPath as String: path]
            for a in Self.fetchAttrs {
                if let v = MDQueryGetAttributeValueOfResultAtIndex(q, a, i) { d[a as String] = Unmanaged<AnyObject>.fromOpaque(v).takeUnretainedValue() }
            }
            out.append(d)
        }
        return out
    }

    static let fetchAttrs: [CFString] = attrs.filter { $0 != kMDItemPath }

    /// 1 件の属性から FileEntry を作る（種類は名前の拡張子と UTI の両方から）
    static func entry(_ d: [String: Any]) -> FileEntry? {
        guard let p0 = d[kMDItemPath as String] as? String else { return nil }
        let path = p0.precomposedStringWithCanonicalMapping
        let name = (path as NSString).lastPathComponent
        let ct = d[kMDItemContentType as String] as? String ?? ""
        let tree = Set(d[kMDItemContentTypeTree as String] as? [String] ?? [])
        let isDir = ct == "public.folder" || ct == "public.volume"
        var fams = FileCatalog.families(name: name, isDir: isDir)
        if !isDir {
            for (f, us) in familyUTIs where f != "folder" && !fams.contains(f) && us.contains(where: tree.contains) { fams.append(f) }
            if fams.contains("image") && !fams.contains("screenshot") {
                let n = name.lowercased()
                if n.contains("スクリーンショット") || n.contains("screenshot") { fams.append("screenshot") }
            }
        }
        func t(_ k: String) -> Int { Int((d[k] as? Date)?.timeIntervalSince1970 ?? 0) }
        let created = t(kMDItemContentCreationDate as String)
        let froms = (d[kMDItemWhereFroms as String] as? [String])?.isEmpty == false
        return FileEntry(path: path, name: name,
                         parentName: ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent,
                         isDir: isDir, kind: (d[kMDItemKind as String] as? String ?? (isDir ? "フォルダ" : "書類")).precomposedStringWithCanonicalMapping,
                         families: fams, size: (d[kMDItemFSSize as String] as? Int) ?? 0,
                         mtime: t(kMDItemContentModificationDate as String),
                         created: created > 0 ? created : t(kMDItemFSCreationDate as String),
                         added: t("kMDItemDateAdded"), lastUsed: t(kMDItemLastUsedDate as String), usedDays: [],
                         downloaded: froms || path.hasPrefix(home + "/Downloads/"))
    }

    /// 確かめ用（名前の一致の強さ）
    public static func nameStrengthForTest(_ name: String, words: [String]) -> Float { nameStrength(FileEntry(path: "/x/" + name), words: words) }

    /// 確かめ用（属性の辞書から FileEntry を作る）
    public static func entryForTest(_ d: [String: Any]) -> FileEntry? { entry(d) }

    /// 1 件分を Spotlight から（無ければ nil）
    public static func entry(path: String) -> FileEntry? {
        guard let it = MDItemCreate(kCFAllocatorDefault, path as CFString),
              var d = MDItemCopyAttributes(it, attrs as CFArray) as? [String: Any] else { return nil }
        if d[kMDItemPath as String] == nil { d[kMDItemPath as String] = path }
        if d[kMDItemContentType as String] == nil {
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &dir), dir.boolValue { d[kMDItemContentType as String] = "public.folder" }
        }
        return entry(d)
    }

    /// 除外・隠し・パッケージの中か（Spotlight は .app の中や隠しフォルダの物も返す）
    public func excluded(_ path: String) -> Bool {
        if exclude.excludesPath(path) { return true }
        var comps = path.split(separator: "/")
        if !comps.isEmpty { comps.removeLast() }   // 自分の名前は下で見る
        for c in comps {
            let s = String(c)
            if exclude.excludesName(s) || Self.packageExts.contains((s as NSString).pathExtension.lowercased()) { return true }
        }
        let name = (path as NSString).lastPathComponent
        return exclude.excludesName(name)
    }
    /// 中を見ないパッケージの拡張子（.app は ScanScope.excludesName が除く）
    static let packageExts: Set<String> = ["app", "bundle", "framework", "photoslibrary", "musiclibrary", "tvlibrary", "key", "pages",
                                           "numbers", "rtfd", "xcodeproj", "xcworkspace", "playground", "mlmodelc", "mlpackage",
                                           "lproj", "xcassets", "kext", "plugin", "appex", "scnassets", "pkg", "logarchive"]

    // MARK: - 検索

    /// 入力 1 回分（同期。検索の列から呼ぶ）。f は「#」の読み取り結果（コマンドが無い入力なら nil）
    public func search(_ query: String, filters f: QueryFilters?, limit: Int, now: Date = Date()) -> Result {
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        let t0 = Date()
        var req = f.map { Self.request($0, now: now) } ?? Self.request(text: query, now: now)
        var res = Result()
        // #near X: プロジェクトの根を範囲に
        if let x = req.nearAnchor {
            if let p = resolve(x, gen: gen) {
                req.scopes = [Self.projectRoot(of: p)]
            } else { res.note = "「\(x)」が見つかりません"; res.ms = ms(t0); return res }
        }
        // #path の名前: 名前にそれを含むフォルダを範囲に（「/」を含む値は最後の部分で引き、パスの一部かは後でふるう）
        if !req.pathNames.isEmpty && req.scopes.isEmpty {
            var dirs: [String] = []
            for pn in req.pathNames {
                let last = pn.split(separator: "/").last.map(String.init) ?? pn
                let qs = "kMDItemContentType == \"public.folder\" && " + Self.nameClause(last)
                guard let rows = run(qs, scopes: defaultScopes(), max: 400, gen: gen) else { res.cancelled = true; return res }
                for d in rows { if let p = d[kMDItemPath as String] as? String, !excluded(p) { dirs.append(p.precomposedStringWithCanonicalMapping) } }
            }
            // 入れ子は外側だけ
            let sorted = Set(dirs).sorted()
            var top: [String] = []
            for d in sorted where !top.contains(where: { d.hasPrefix($0 + "/") }) { top.append(d) }
            if top.isEmpty { res.ms = ms(t0); res.note = "「\(req.pathNames.joined(separator: "・"))」のフォルダが見つかりません"; return res }
            req.scopes = Array(top.prefix(200))
        }
        // #with X: X を使った時刻の前後
        var withTime: Int?
        var anchorPath: String?
        var co: [String: Float] = [:]
        if let x = req.withAnchor {
            guard let p = resolve(x, gen: gen), let e = Self.entry(path: p) else { res.note = "「\(x)」が見つかりません"; res.ms = ms(t0); return res }
            anchorPath = p
            let t = e.lastUsed > 0 ? e.lastUsed : max(e.mtime, e.added)
            withTime = t > 0 ? t : nil
            co = coUsed(p)
        }
        let scopes = req.scopes.isEmpty ? defaultScopes() : req.scopes
        let text = Self.queryString(req, withTime: withTime)
        res.query = text; res.scopes = scopes
        guard var rows = run(text, scopes: scopes, max: Self.fetchLimit, gen: gen) else { res.cancelled = true; res.ms = ms(t0); return res }
        res.fetched = rows.count
        // ホーム直下のファイル（範囲にできないので 1 段だけ見る）
        if req.scopes.isEmpty, let names = try? FileManager.default.contentsOfDirectory(atPath: Self.home) {
            for n in names where !n.hasPrefix(".") {
                let p = Self.home + "/" + n
                var dir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &dir), !dir.boolValue,
                      let it = MDItemCreate(kCFAllocatorDefault, p as CFString),
                      var d = MDItemCopyAttributes(it, Self.attrs as CFArray) as? [String: Any] else { continue }
                if d[kMDItemPath as String] == nil { d[kMDItemPath as String] = p }
                rows.append(d)
            }
        }
        var entries: [FileEntry] = []
        var seen = Set<String>()
        for d in rows {
            guard let e = Self.entry(d), seen.insert(e.path).inserted, !excluded(e.path), e.path != anchorPath else { continue }
            guard passes(e, req: req, display: d[kMDItemDisplayName as String] as? String) else { continue }
            entries.append(e)
        }
        // 「選んだ」の記録と #with の線の先は、Spotlight の結果に無くても条件に合えば入れる
        let exs = examples()
        let exScore = Self.exampleScores(query, exs)
        var extra = Set(exScore.filter { $0.value >= 0.35 }.map(\.key))
        extra.formUnion(co.keys)
        for p in extra where !seen.contains(p) && p != anchorPath && !excluded(p) {
            guard FileManager.default.fileExists(atPath: p), let e = Self.entry(path: p), passes(e, req: req, display: nil) else { continue }
            seen.insert(p); entries.append(e)
        }
        let maxCo = co.values.max() ?? 0
        let nowT = Int(now.timeIntervalSince1970)
        var scored: [(FileEntry, Float)] = entries.map { e in
            var s = Self.nameStrength(e, words: req.words + (req.names.count == 1 ? req.names : []))
            let t = max(e.lastUsed, e.mtime)
            if t > 0 { s += 0.2 * Float(exp(-Double(max(0, nowT - t)) / 86400 / 30)) }
            s += exScore[e.path] ?? 0
            if maxCo > 0, let w = co[e.path] { s += 0.3 * w / maxCo }
            return (e, s)
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path < $1.0.path }
        res.files = scored.prefix(limit).map { FileResult(file: $0.0, score: $0.1) }
        res.ms = ms(t0)
        lock.lock(); lastMs = res.ms; lastQuery = text; lock.unlock()
        return res
    }

    private func ms(_ t0: Date) -> Double { Date().timeIntervalSince(t0) * 1000 }

    /// 条件に合うか（Spotlight で表せない所と、名前の言葉を Raiden の側で見直す）
    func passes(_ e: FileEntry, req: Request, display: String?) -> Bool {
        let keys = [Describe.normalize(e.name), display.map(Describe.normalize) ?? ""].filter { !$0.isEmpty }
        if !req.words.isEmpty && !req.words.map(Describe.normalize).contains(where: { w in keys.contains { $0.contains(w) } }) { return false }
        if !req.names.isEmpty && !req.names.contains(where: { n in keys.contains { $0.contains(n) } }) { return false }
        if req.types == ["d"] && !e.isDir { return false }
        if req.types == ["f"] && e.isDir { return false }
        if req.download && !e.downloaded { return false }
        if !req.families.isEmpty || !req.kindExts.isEmpty {
            let ext = (e.name as NSString).pathExtension.lowercased()
            let fam = Set(e.families)
            if e.isDir ? !req.families.contains("folder") : (req.families.isDisjoint(with: fam) && !req.kindExts.contains(ext)) { return false }
        }
        if let f = req.post {
            // 名前と種類は上で見たので外す（Spotlight の表示名でも当たりにする・UTI の種類も当たりにするため）
            if !f.without(.name).without(.kind).matches(e) { return false }
        } else {
            for (c, rg) in req.dates where !QueryFilters.dateHit(c, e, rg) { return false }
            for pn in req.pathNames where !QueryFilters.isUnder(e.path, pn) { return false }
        }
        return true
    }

    /// 名前の一致の強さ（言葉ごとに 先頭・単語の先頭 0.6、途中 0.35 の平均）。名前は拡張子を除いた形で見る
    static func nameStrength(_ e: FileEntry, words: [String]) -> Float {
        guard !words.isEmpty else { return 0 }
        let n = Describe.normalize(e.stem)
        let parts = n.split(whereSeparator: { " -_.".contains($0) })
        var sum: Float = 0
        for w0 in words {
            let w = Describe.normalize(w0)
            if n.hasPrefix(w) || parts.contains(where: { $0.hasPrefix(w) }) { sum += 0.6 } else if n.contains(w) { sum += 0.35 }
        }
        return sum / Float(words.count)
    }

    /// 「選んだ」の記録の加点（パス → 点）。入力と記録の入力の 2 文字の組の重なり（Dice）が 0.5 以上なら 0.5 × 重なり。
    /// 同じパスに何件あれば一番高い物。回数が多いほど少し上げる（log2(1+回数) / 2、最大 1）
    public static func exampleScores(_ q: String, _ exs: [(String, String, Float)]) -> [String: Float] {
        let a = grams(q)
        guard !a.isEmpty else { return [:] }
        var out: [String: Float] = [:]
        for (t, p, w) in exs {
            let b = grams(t)
            guard !b.isEmpty else { continue }
            let sim = 2 * Float(a.intersection(b).count) / Float(a.count + b.count)
            guard sim >= 0.5 else { continue }
            let s = 0.5 * sim * min(1, 0.5 + log2(1 + w) / 2)
            out[p] = max(out[p] ?? 0, s)
        }
        return out
    }

    /// 2 文字の組（空白を除く。1 文字の入力はその 1 文字）
    static func grams(_ s: String) -> Set<String> {
        let cs = Array(Describe.normalize(s).filter { !$0.isWhitespace })
        if cs.count == 1 { return [String(cs)] }
        guard cs.count >= 2 else { return [] }
        return Set((0..<(cs.count - 1)).map { String(cs[$0...$0 + 1]) })
    }

    // MARK: - #with / #near の X

    /// X を実際のパスにする。「~/」「/」で始まればそのパス、そうでなければ名前がそれに一致する物（同じ名前 → 名前に含む物の順、
    /// その中は使った日の新しい順）を Spotlight で引く
    public func resolve(_ x: String, gen: Int? = nil) -> String? {
        let v = x.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return nil }
        if v.hasPrefix("~") || v.hasPrefix("/") {
            let p = ScanScope.norm(v)
            return FileManager.default.fileExists(atPath: p) ? p : nil
        }
        let g: Int
        if let gen { g = gen } else { lock.lock(); g = generation; lock.unlock() }
        let e = Self.esc(v)
        let qs = "kMDItemFSName == \"\(e)\"cd || kMDItemDisplayName == \"\(e)\"cd || " + Self.nameClause(v)
        guard let rows = run(qs, scopes: defaultScopes(), max: 500, gen: g) else { return nil }
        let nv = Describe.normalize(v)
        let cands = rows.compactMap(Self.entry).filter { !excluded($0.path) }
        func rank(_ e: FileEntry) -> (Int, Int) {
            let n = Describe.normalize(e.name), s = Describe.normalize(e.stem)
            return (n == nv || s == nv ? 0 : 1, -max(e.lastUsed, e.mtime))
        }
        return cands.min { rank($0) < rank($1) }?.path
    }

    /// プロジェクトの根を表す印（フォルダの中にこれがあれば根）
    public static let projectMarkers = [".git", "package.json", "Package.swift", "Cargo.toml", "pyproject.toml"]
    public static let projectMarkerExts = ["xcodeproj", "xcworkspace"]

    /// X から親をさかのぼって最初に見つかるプロジェクトの根（.git・package.json・Package.swift・*.xcodeproj・*.xcworkspace・
    /// Cargo.toml・pyproject.toml、Unity の Assets と ProjectSettings の両方）。X がフォルダなら X 自身から見る。
    /// ~ か / まで上がったら止め、見つからなければ X の親フォルダ
    public static func projectRoot(of x: String) -> String {
        let fm = FileManager.default
        var dir: ObjCBool = false
        let isDir = fm.fileExists(atPath: x, isDirectory: &dir) && dir.boolValue
        let parent = (x as NSString).deletingLastPathComponent
        var cur = isDir ? x : parent
        while cur != home && cur != "/" && !cur.isEmpty {
            if isRoot(cur) { return cur }
            cur = (cur as NSString).deletingLastPathComponent
        }
        return parent
    }

    static func isRoot(_ d: String) -> Bool {
        let fm = FileManager.default
        for m in projectMarkers where fm.fileExists(atPath: d + "/" + m) { return true }
        let names = (try? fm.contentsOfDirectory(atPath: d)) ?? []
        if names.contains(where: { projectMarkerExts.contains(($0 as NSString).pathExtension) }) { return true }
        return names.contains("Assets") && names.contains("ProjectSettings")
    }

    // MARK: - 「#」の担当向けの口

    /// 最近使ったファイル・フォルダ（kMDItemLastUsedDate の新しい順、limit 件まで）。7 日 → 30 日 → 1 年と広げて引く
    public func recent(limit: Int = 20, now: Date = Date()) -> [FileEntry] {
        lock.lock(); let g = generation; lock.unlock()
        let t = Int(now.timeIntervalSince1970)
        var out: [FileEntry] = []
        for days in [7, 30, 365] {
            let qs = "kMDItemLastUsedDate >= \(Self.iso(t - days * 86400))"
            guard let rows = run(qs, scopes: defaultScopes(), max: Self.fetchLimit, gen: g) else { return [] }
            out = rows.compactMap(Self.entry).filter { !excluded($0.path) && $0.lastUsed > 0 }
            if out.count >= limit { break }
        }
        return Array(out.sorted { $0.lastUsed > $1.lastUsed }.prefix(limit))
    }

    /// 条件に合う物の数（値の候補の件数用の目安。exactCountMax 件以下なら除外・パッケージの中を引く。多いときは Spotlight の数のまま）。
    /// max を超えたら max を返す
    /// 件数を数える上限。ここまで行ったら「1万件以上」と出す（FilterCompletion.countText）
    public static let countCap = 10_000

    public func count(_ f: QueryFilters, max: Int = SpotlightSearch.countCap, now: Date = Date()) -> Int {
        lock.lock(); let g = generation; lock.unlock()
        let r = Self.request(f, now: now)
        guard let q = MDQueryCreate(kCFAllocatorDefault, Self.queryString(r) as CFString, nil, nil) else { return 0 }
        MDQuerySetSearchScope(q, (r.scopes.isEmpty ? defaultScopes() : r.scopes) as CFArray, 0)
        MDQuerySetMaxCount(q, max)
        _ = g
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return 0 }
        let n = MDQueryGetResultCount(q)
        // 少ないときは除外（Library・build・パッケージの中など）を引いて数え直す。結果の一覧と食い違って
        // 「6 件」なのに「条件に合う物はありません」になるのは、件数が小さいときほど目立つため
        guard n <= Self.exactCountMax else { return n }
        var kept = 0
        for i in 0..<n {
            guard let raw = MDQueryGetResultAtIndex(q, i) else { continue }
            let item = unsafeBitCast(raw, to: MDItem.self)
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String, !excluded(path) { kept += 1 }
        }
        return kept
    }

    /// これ以下の件数なら除外を引いて数え直す
    static let exactCountMax = 2000
}

/// 入力欄の値の候補の件数と「最近使った物」を Spotlight で答える（FilterSource。AppDelegate が FilterInput.context に渡す）。
/// Spotlight は 1 回 150ms ほどかかるので、入力欄の列では待たない: 覚えている答えが無ければ nil（件数なし）を返して裏で数え、
/// 届いたら onUpdate を呼ぶ（AppDelegate が FilterInput.sourceDidUpdate で一覧を出し直す）。覚えた件数は 60 秒で捨てる。
/// 件数は Spotlight の数のまま（除外・パッケージの中のふるい直しはしない目安）。#with・#near が付いているときは数えない
public final class SpotlightFilterSource: FilterSource, @unchecked Sendable {
    public let search: SpotlightSearch
    public var appCount: Int { appCountProvider() }
    public var appCountProvider: () -> Int = { 0 }
    /// 裏で数え終わったとき（どの列からでも呼ぶので、受け取る側で main に移す）
    public var onUpdate: () -> Void = {}
    public static let ttl: TimeInterval = 60

    private let lock = NSLock()
    private var cache: [String: (Int, Date)] = [:]
    private var inFlight = Set<String>()
    private var recent: [FileEntry] = []
    private var recentAt = Date.distantPast
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    public init(search: SpotlightSearch) { self.search = search }

    /// 入力欄を開いたときに呼ぶ（最近使った物を裏で取り直す。30 秒以内なら取り直さない）
    public func refreshRecent() {
        lock.lock()
        let stale = Date().timeIntervalSince(recentAt) > 30
        if stale { recentAt = Date() }
        lock.unlock()
        guard stale else { return }
        queue.addOperation { [weak self] in
            guard let self else { return }
            let r = self.search.recent(limit: 40)
            self.lock.lock(); self.recent = r; self.lock.unlock()
            self.onUpdate()
        }
    }

    static func key(_ f: QueryFilters) -> String? {
        if f.hasRelation { return nil }
        let r = SpotlightSearch.request(f)
        return SpotlightSearch.queryString(r) + "\u{1}" + r.scopes.joined(separator: "\u{1}") + "\u{1}" + r.pathNames.joined(separator: "\u{1}")
    }

    /// 覚えていれば件数、無ければ裏で数え始めて nil
    func cached(_ f: QueryFilters) -> Int? {
        guard let k = Self.key(f) else { return nil }
        lock.lock()
        if let (n, t) = cache[k], Date().timeIntervalSince(t) < Self.ttl { lock.unlock(); return n }
        let start = inFlight.insert(k).inserted
        lock.unlock()
        if start {
            queue.addOperation { [weak self] in
                guard let self else { return }
                let n = self.search.count(f)
                self.lock.lock(); self.cache[k] = (n, Date()); self.inFlight.remove(k); self.lock.unlock()
                self.onUpdate()
            }
        }
        return nil
    }

    public func counts(_ cmd: QueryFilters.Command, values: [String], within others: QueryFilters, now: Date) -> [String: Int]? {
        if cmd == .with || cmd == .near || others.hasRelation { return nil }
        var out: [String: Int] = [:]
        for v in values {
            var f = others
            guard f.apply(cmd, v, now: now) != nil else { out[v] = 0; continue }
            if let n = cached(f) { out[v] = n }
        }
        return out.isEmpty ? nil : out
    }

    public func total(_ f: QueryFilters) -> Int? { cached(f) }

    public func recentFiles(limit: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(recent.prefix(limit).map(\.path))
    }

    public func recentFolders(limit: Int) -> [String] {
        lock.lock(); let r = recent; lock.unlock()
        var out: [String] = []
        for e in r {
            let d = e.isDir ? e.path : (e.path as NSString).deletingLastPathComponent
            if !out.contains(d) { out.append(d) }
            if out.count >= limit { break }
        }
        return out
    }
}
