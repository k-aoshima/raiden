import CoreServices
import Foundation

/// 入っているアプリ 1 個分。key は bundle id（無ければパス）。
public struct AppEntry: Sendable, Hashable {
    public let key: String
    public let bundleID: String
    public let path: String
    public let name: String      // CFBundleDisplayName / CFBundleName（英語名のことが多い）
    public let jp: String        // Finder の表示名（日本語環境なら日本語名）
    public let category: String  // LSApplicationCategoryType
    public let docs: [String]    // CFBundleDocumentTypes から拾った種類名・UTI・拡張子
    public let extra: String     // 標準アプリ以外の説明の材料（AppExtra）。無ければ空
    public var opens: [String: Int] = [:]  // 手元のファイルをこのアプリで開く件数（種類 → 件数。OpenWithIndex）
    public var lastUsed = 0                // 最後に使った日時（Spotlight の kMDItemLastUsedDate。無ければ 0）
}

public enum AppCatalog {
    public static let dirs: [String] = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
        "/System/Library/CoreServices/Applications",
    ]

    static func spotlightName(_ path: String) -> String? {
        guard let item = MDItemCreate(nil, path as CFString),
              let n = MDItemCopyAttribute(item, kMDItemDisplayName) as? String, !n.isEmpty else { return nil }
        return n
    }

    /// Spotlight で見つけた .app のうち、上の dirs の直下に無いもの（外付けドライブ・/Applications の下のフォルダ・
    /// Unity Hub が入れたエディタなど）。拾うのは次のどちらかに当たるものだけ:
    ///   - 「Applications」という名前のフォルダの直下か、その下のフォルダ 1 段の中（/Applications/Live2D Cubism 5.3/…）
    ///   - Unity Hub の Editor の下（…/Hub/Editor/<版>/Unity.app。Hub の置き場所は自由に変えられる）
    /// 除くもの: ほかのアプリの中（.app/ の下）、Library の下（補助ツール・更新係・Steam のゲーム本体）、
    /// Xcode や開発のビルド物（DerivedData・build・.build・dist・release・target・CoreSimulator）、ゴミ箱、
    /// Chrome が作るサイトのショートカット（Chrome Apps）、アンインストーラ、今は無いもの（外付けが外れた後の索引）。
    /// RAIDEN_NO_SPOTLIGHT=1 で使わない（前の作りと比べる用）。
    public static func spotlightPaths() -> [String] {
        if ProcessInfo.processInfo.environment["RAIDEN_NO_SPOTLIGHT"] == "1" { return [] }
        let qs = "kMDItemContentType == \"com.apple.application-bundle\"" as CFString
        guard let q = MDQueryCreate(kCFAllocatorDefault, qs, nil, nil) else { return [] }
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        let known = Set(dirs)
        let fm = FileManager.default
        var out: [String] = []
        for i in 0..<MDQueryGetResultCount(q) {
            guard let raw = MDQueryGetResultAtIndex(q, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  isCandidate(path, known: known), fm.fileExists(atPath: path + "/Contents/Info.plist") else { continue }
            out.append(path)
        }
        return out.sorted()
    }

    static let skipDirs: Set<String> = [
        "Library", "DerivedData", "build", ".build", "dist", "release", "target", "CoreSimulator",
        ".Trash", ".Trashes", "Trash", "node_modules", "Chrome Apps.localized", "Chrome Apps",
    ]

    /// Spotlight の結果のうち一覧に足すものか（パスだけで決める）
    static func isCandidate(_ path: String, known: Set<String>) -> Bool {
        guard path.hasSuffix(".app") else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        if known.contains(parent) { return false }  // dirs の直下はいつもの道で拾う
        let comps = parent.split(separator: "/").map(String.init)
        if comps.contains(where: { $0.hasSuffix(".app") || skipDirs.contains($0) }) { return false }
        let file = (path as NSString).lastPathComponent
        if file.lowercased().contains("uninstall") { return false }
        if let i = comps.lastIndex(of: "Applications"), comps.count - i <= 2 { return true }
        // Unity Hub のエディタ: …/Hub/Editor/<版>/Unity.app
        let n = comps.count
        if file == "Unity.app", n >= 3, comps[n - 3] == "Hub", comps[n - 2] == "Editor" { return true }
        return false
    }

    /// 同じ bundle id が Spotlight で複数見つかったら新しい版を先に（古い版は seen で落ちる）
    static func newerFirst(_ paths: [String]) -> [String] {
        func ver(_ p: String) -> String {
            let info = NSDictionary(contentsOfFile: p + "/Contents/Info.plist")
            return (info?["CFBundleShortVersionString"] as? String) ?? (info?["CFBundleVersion"] as? String) ?? ""
        }
        let vs = Dictionary(uniqueKeysWithValues: paths.map { ($0, ver($0)) })
        return paths.sorted { a, b in
            let c = vs[a]!.compare(vs[b]!, options: .numeric)
            return c == .orderedSame ? a < b : c == .orderedDescending
        }
    }

    /// extras: false で AppExtra と「いつも開くファイル」を使わない（答え合わせで前の作りと比べる用）
    /// opens: 手元のファイルを開くアプリの一覧。nil なら extras のときだけここで作る
    public static func collect(extras: Bool = true, opens: OpenWithIndex? = nil) -> [AppEntry] {
        let fm = FileManager.default
        let ctx = extras ? AppExtra.Context.load() : nil
        let openCounts = (opens ?? (extras ? OpenWithIndex.build() : OpenWithIndex())).counts()
        var out: [AppEntry] = []
        var seen = Set<String>()
        var paths: [String] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            // 隠しアプリ（.Karabiner-VirtualHIDDevice-Manager のようなドライバの管理係）は出さない
            paths += items.sorted().filter { $0.hasSuffix(".app") && !$0.hasPrefix(".") }.map { dir + "/" + $0 }
        }
        paths += newerFirst(spotlightPaths())
        for path in paths {
            let item = (path as NSString).lastPathComponent
            guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any] else { continue }
            let bid = info["CFBundleIdentifier"] as? String ?? ""
            let key = bid.isEmpty ? path : bid
            if seen.contains(key) { continue }  // 同じ bundle id は最初の 1 個だけ
            seen.insert(key)
            var docs = Set<String>()
            for t in info["CFBundleDocumentTypes"] as? [[String: Any]] ?? [] {
                if let n = t["CFBundleTypeName"] as? String { docs.insert(n) }
                for x in t["LSItemContentTypes"] as? [String] ?? [] { docs.insert(x) }
                for x in t["CFBundleTypeExtensions"] as? [String] ?? [] { docs.insert(x) }
            }
            docs.remove("*"); docs.remove("")
            let base = String(item.dropLast(4))
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? base
            // 表示名は濁点が分かれた NFD で返ることがあるので NFC に揃える（揃えないと当たりが大きく落ちる）
            // Spotlight の kMDItemDisplayName（mdls と同じ。プロセスの言語に左右されず日本語名が返る）
            var jp = spotlightName(path) ?? fm.displayName(atPath: path)
            jp = jp.precomposedStringWithCanonicalMapping
            if jp.hasSuffix(".app") { jp = String(jp.dropLast(4)) }
            let nameNFC = name.precomposedStringWithCanonicalMapping
            let jpNFC = jp.isEmpty ? base.precomposedStringWithCanonicalMapping : jp
            let extra = ctx.map { AppExtra.text(path: path, info: info, bundleID: bid, names: [jpNFC, nameNFC, base], ctx: $0) } ?? ""
            var entry = AppEntry(
                key: key, bundleID: bid, path: path,
                name: nameNFC, jp: jpNFC,
                category: info["LSApplicationCategoryType"] as? String ?? "",
                docs: Array(docs.sorted().prefix(40)), extra: extra, opens: openCounts[key] ?? [:])
            if let it = MDItemCreate(nil, path as CFString), let d = MDItemCopyAttribute(it, kMDItemLastUsedDate) as? Date {
                entry.lastUsed = Int(d.timeIntervalSince1970)
            }
            out.append(entry)
        }
        return out
    }
}
