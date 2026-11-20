import Darwin
import Foundation

/// 検索の対象範囲（探すフォルダ・除くフォルダ・除く名前）。FileCatalog / FileIndex / OpenWithIndex に渡す。
/// 隠しファイル（. で始まる名前）・パッケージの中・.app は常に除く（設定では変えない）。
public struct ScanScope: Equatable, Sendable {
    public var roots: [String]          // 探す場所（絶対パス、NFC）
    public var excludeDirs: [String]    // この中は見ない（絶対パス、NFC）
    public var excludeNames: [String]   // この名前の物は（フォルダなら中も）見ない。* ? [ ] のパターンも使える

    public init(roots: [String], excludeDirs: [String] = [], excludeNames: [String] = ScanScope.defaultExcludeNames) {
        self.roots = roots.map(ScanScope.norm)
        self.excludeDirs = excludeDirs.map(ScanScope.norm)
        self.excludeNames = excludeNames.map { $0.precomposedStringWithCanonicalMapping }.filter { !$0.isEmpty }
        exact = Set(self.excludeNames.filter { !$0.contains(where: { "*?[".contains($0) }) })
        globs = self.excludeNames.filter { $0.contains(where: { "*?[".contains($0) }) }
    }

    private var exact: Set<String>
    private var globs: [String]

    public static func == (a: ScanScope, b: ScanScope) -> Bool {
        a.roots == b.roots && a.excludeDirs == b.excludeDirs && a.excludeNames == b.excludeNames
    }

    /// 今までの決め打ちと同じ（FileCatalog.defaultRoots と node_modules などの除外）
    public static var `default`: ScanScope { ScanScope(roots: FileCatalog.defaultRoots) }
    /// 除外する名前の初期値。キャッシュ・ビルド物・依存の置き場（中身は数万件になりやすく、探す物ではない）。
    /// . で始まる名前（.git .venv .build .next .cache）は隠しファイルとして常に除くが、設定で見えるよう載せておく
    public static let defaultExcludeNames = ["node_modules", ".venv", "venv", "__pycache__", ".git", "DerivedData", "Pods",
                                             "build", ".build", "dist", "target", ".next", ".cache", "*.log"]
    /// 2026-11-20 より前の初期値（これだけ知っている settings.json には、増えた分だけを足す）
    public static let legacyExcludeNames = ["node_modules", ".venv", "venv", "__pycache__", ".git", "DerivedData", "Pods"]

    /// ~ を広げ、シンボリックリンクをたどった実際のパスにする（列挙や FSEvents は実際のパスで返すため。/var → /private/var など）
    static func norm(_ p: String) -> String {
        var s = (p as NSString).expandingTildeInPath
        if let r = realpath(s, nil) { s = String(cString: r); free(r) }
        s = s.precomposedStringWithCanonicalMapping
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 名前で除くか（隠しファイルと .app も含む）
    public func excludesName(_ name: String) -> Bool {
        if name.hasPrefix(".") || name.hasSuffix(".app") { return true }
        let n = name.precomposedStringWithCanonicalMapping
        if exact.contains(n) { return true }
        return globs.contains { fnmatch($0, n, 0) == 0 }
    }

    /// 除くフォルダそのものか、その中か
    public func excludesPath(_ path: String) -> Bool {
        excludeDirs.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

/// 入力欄の節の並び
public enum SectionOrder: String, Codable, CaseIterable, Sendable {
    case auto, appsFirst, filesFirst
    public var label: String {
        switch self {
        case .auto: return "自動（言い方で決める）"
        case .appsFirst: return "アプリを先に"
        case .filesFirst: return "ファイルを先に"
        }
    }
}

/// 設定（~/Library/Application Support/Raiden/settings.json）。読めない・無い項目は初期値。
/// ログイン時に起動はシステムの登録（SMAppService）が正なので、ここには持たない。
public struct RaidenSettings: Codable, Equatable, Sendable {
    public struct Folder: Codable, Equatable, Sendable {
        public var path: String      // 保存は ~/ で短くした形
        public var enabled: Bool
        public init(path: String, enabled: Bool = true) { self.path = path; self.enabled = enabled }
        public var absolutePath: String { ScanScope.norm(path) }
    }
    public struct HotKeySetting: Codable, Equatable, Sendable {
        public var keyCode: UInt32
        public var modifiers: UInt32   // Carbon の修飾キー（cmdKey / optionKey ...）
        public var label: String
        public init(keyCode: UInt32, modifiers: UInt32, label: String) {
            self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
        }
    }

    public var version = 1
    // 検索範囲
    public var folders: [Folder] = RaidenSettings.defaultFolders
    public var excludeFolders: [String] = []
    public var excludeNames: [String] = ScanScope.defaultExcludeNames
    /// 今まで足した除外の初期値。初期値が増えたら、ここに無い分だけを excludeNames に足す（ユーザーが消した物は戻さない）
    public var knownExcludeDefaults: [String] = ScanScope.defaultExcludeNames
    // 一般
    public var hotKey: HotKeySetting?          // nil = 既定（⌥Space、取れなければ ⌃⌥⌘Space）
    public var unloadMinutes = 0               // 入力欄を閉じてから何分でモデルを解放するか（0 = 解放しない）
    public var maxRows = 9                     // 候補の最大件数（アプリ＋ファイル）
    public var sectionOrder: SectionOrder = .auto
    public var transparency = RaidenSettings.defaultTransparency  // 入力欄と設定窓の透け具合（0 = 白い、0.9 = いちばん透ける）
    // 学習
    public var learn = true                    // 選んだ結果を覚える
    public var dictionary: [DictEntry] = []       // 辞書（言い方 → アプリ / ファイル・フォルダ / 「#」の条件）
    public var savedFilters: [SavedFilter] = []  // 名前を付けて保存した絞り込み（#仕事のPDF → #ext pdf #path 仕事）
    // 記録
    public var logSearches = true              // 検索の記録を残す
    public var logDays = 90                    // 残す日数

    public init() {}

    public static var defaultFolders: [Folder] {
        ["~/Documents", "~/Downloads", "~/Desktop", "~/Documents/Obsidian Vault"].map { Folder(path: $0) }
    }
    public static let maxRowsRange = 5...15
    public static let defaultTransparency = 0.6
    public static let transparencyRange = 0.0...0.9

    public static var defaultURL: URL { RaidenPaths.support.appendingPathComponent("settings.json") }

    public var scope: ScanScope {
        ScanScope(roots: folders.filter(\.enabled).map(\.absolutePath),
                  excludeDirs: excludeFolders.map(ScanScope.norm), excludeNames: excludeNames)
    }

    /// ~/ で短くする（保存と表示用）
    public static func tilde(_ p: String) -> String {
        let home = NSHomeDirectory()
        let n = ScanScope.norm(p)
        if n == home { return "~" }
        return n.hasPrefix(home + "/") ? "~" + n.dropFirst(home.count) : n
    }

    // 項目ごとに読めなければ初期値（古い版・壊れた値で全部が初期値に戻らないように）
    enum CodingKeys: String, CodingKey {
        case version, folders, excludeFolders, excludeNames, knownExcludeDefaults, hotKey, unloadMinutes, maxRows, sectionOrder, transparency, learn, dictionary, savedFilters, logSearches, logDays
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = RaidenSettings()
        func get<T: Decodable>(_ k: CodingKeys, _ dv: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)).flatMap { $0 } ?? dv }
        version = get(.version, def.version)
        folders = get(.folders, def.folders)
        excludeFolders = get(.excludeFolders, def.excludeFolders)
        excludeNames = get(.excludeNames, def.excludeNames)
        // 初期値が増えた分だけを足す。knownExcludeDefaults が無いのは前の版の settings.json（前の初期値だけを知っている）
        let known = get(.knownExcludeDefaults, ScanScope.legacyExcludeNames)
        for n in ScanScope.defaultExcludeNames where !known.contains(n) && !excludeNames.contains(n) { excludeNames.append(n) }
        knownExcludeDefaults = known + ScanScope.defaultExcludeNames.filter { !known.contains($0) }
        hotKey = (try? c.decodeIfPresent(HotKeySetting.self, forKey: .hotKey)) ?? nil
        unloadMinutes = max(0, get(.unloadMinutes, def.unloadMinutes))
        maxRows = min(max(get(.maxRows, def.maxRows), Self.maxRowsRange.lowerBound), Self.maxRowsRange.upperBound)
        sectionOrder = get(.sectionOrder, def.sectionOrder)
        transparency = min(max(get(.transparency, def.transparency), Self.transparencyRange.lowerBound), Self.transparencyRange.upperBound)
        learn = get(.learn, def.learn)
        dictionary = get(.dictionary, def.dictionary).filter { !$0.phrase.isEmpty && !$0.key.isEmpty }
        savedFilters = get(.savedFilters, def.savedFilters).filter { !$0.name.isEmpty && !$0.commands.isEmpty }
        logSearches = get(.logSearches, def.logSearches)
        logDays = max(1, get(.logDays, def.logDays))
    }

    /// 読む。無い・読めないときは初期値
    public static func load(from url: URL = defaultURL) -> RaidenSettings {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(RaidenSettings.self, from: d) else {
            return RaidenSettings()
        }
        return s
    }

    /// 書く（いったん別名に書いてから置き換える）
    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

/// 範囲の中の件数を数える（設定窓の各行・広すぎる場所の注意用）。limit を超えたら数えるのをやめる
public enum ScopeCounter {
    public struct Result: Sendable {
        public var count: Int
        public var capped: Bool
        public init(count: Int, capped: Bool) { self.count = count; self.capped = capped }
    }

    public static func count(root: String, scope: ScanScope, limit: Int = 200_000, cancelled: () -> Bool = { false }) -> Result {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return Result(count: 0, capped: false) }
        var n = 0
        for case let url as URL in en {
            if scope.excludesName(url.lastPathComponent) || scope.excludesPath(url.path.precomposedStringWithCanonicalMapping) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { en.skipDescendants() }
                continue
            }
            n += 1
            if n >= limit { return Result(count: n, capped: true) }
            if n % 2000 == 0 && cancelled() { break }
        }
        return Result(count: n, capped: false)
    }

    /// 広すぎる場所の目安。ANE 版のアプリに ~/Project 168,530 件を入れた実測（2026-11-20）から:
    /// footprint 1,311MB（1 件約 8.0KB）、DB 102MB（1 件約 0.6KB）、初回のベクトル化 749 秒（短い説明と中身を読む作り直しを合わせて 1 件約 4.5ms）
    public static let warnAbove = 50_000
    public static func estimate(_ n: Int) -> (memoryMB: Int, dbMB: Int, minutes: Int) {
        (Int(Double(n) * 8.0 / 1024.0), Int(Double(n) * 0.6 / 1024.0), Int((Double(n) * 0.0045 / 60).rounded(.up)))
    }
}
