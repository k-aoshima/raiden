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

    public static func collect() -> [AppEntry] {
        let fm = FileManager.default
        var out: [AppEntry] = []
        var seen = Set<String>()
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items.sorted() where item.hasSuffix(".app") {
                let path = dir + "/" + item
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
                out.append(AppEntry(
                    key: key, bundleID: bid, path: path,
                    name: name.precomposedStringWithCanonicalMapping,
                    jp: jp.isEmpty ? base.precomposedStringWithCanonicalMapping : jp,
                    category: info["LSApplicationCategoryType"] as? String ?? "",
                    docs: Array(docs.sorted().prefix(40))))
            }
        }
        return out
    }
}
