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

    /// extras: false で AppExtra と「いつも開くファイル」を使わない（答え合わせで前の作りと比べる用）
    /// opens: 手元のファイルを開くアプリの一覧。nil なら extras のときだけここで作る
    public static func collect(extras: Bool = true, opens: OpenWithIndex? = nil) -> [AppEntry] {
        let fm = FileManager.default
        let ctx = extras ? AppExtra.Context.load() : nil
        let openCounts = (opens ?? (extras ? OpenWithIndex.build() : OpenWithIndex())).counts()
        var out: [AppEntry] = []
        var seen = Set<String>()
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items.sorted() where item.hasSuffix(".app") {
                let path = dir + "/" + item
                guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any] else { continue }
                let bid = info["CFBundleIdentifier"] as? String ?? ""
                if bid == "com.kosuke.raiden" { continue }  // Raiden 自身は候補に出さない
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
                out.append(AppEntry(
                    key: key, bundleID: bid, path: path,
                    name: nameNFC, jp: jpNFC,
                    category: info["LSApplicationCategoryType"] as? String ?? "",
                    docs: Array(docs.sorted().prefix(40)), extra: extra, opens: openCounts[key] ?? [:]))
            }
        }
        return out
    }
}
