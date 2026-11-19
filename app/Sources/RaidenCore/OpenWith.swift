import AppKit
import Foundation

/// 手元のファイル 1 件ずつの「開くアプリ」。NSWorkspace.urlForApplication(toOpen: ファイルの URL) は、
/// Finder の「このアプリケーションで開く」の個別設定があればそれを、無ければ種類の既定を返す。
/// ~/Documents・Downloads・Desktop の 800 件ほどで 0.1 秒かからないので、一覧を作るたびに全部調べる。
/// ファイルが増えた・変わった・消えたときは update / remove でその分だけ調べ直せる（FSEvents から呼ぶ想定）。
///
/// 使い道:
///   - アプリの説明文の「いつも開くファイル: PDF（手元に 49 個）」（counts → AppEntry.opens → Describe）
///   - 「PDF を見るやつ」でいつも PDF を開くアプリに足す点（Engine.openBonus）
///   - グラフの線 app → file（opens。Store.replaceOpens）
public struct OpenWithIndex: Sendable {
    /// ファイルのパス → アプリのキー（AppEntry.key と同じ。bundle id、無ければアプリのパス）
    public private(set) var byFile: [String: String] = [:]
    private var appKeyCache: [String: String] = [:]

    public init() {}

    static let skipDirs: Set<String> = ["node_modules", ".venv", "venv", "__pycache__", ".git", "DerivedData", "Pods"]

    /// 探す場所はファイル検索と同じ（FileCatalog.defaultRoots）
    public static func build(roots: [String] = FileCatalog.defaultRoots) -> OpenWithIndex {
        var idx = OpenWithIndex()
        idx.update(listFiles(roots: roots))
        return idx
    }

    /// ファイルだけを軽く並べる（隠しファイル・パッケージの中・.app・node_modules などは除く）
    public static func listFiles(roots: [String]) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        var seen = Set<String>()
        for root in roots {
            guard let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in en {
                let name = url.lastPathComponent
                let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if skipDirs.contains(name) || name.hasSuffix(".app") {
                    if rv?.isDirectory == true { en.skipDescendants() }
                    continue
                }
                if rv?.isDirectory == true && rv?.isPackage != true { continue }
                let p = url.path.precomposedStringWithCanonicalMapping
                if seen.insert(p).inserted { out.append(p) }
            }
        }
        return out
    }

    /// 開くアプリの URL → AppEntry.key（Safari のように実体が別の場所にあるアプリもあるので bundle id で合わせる）
    mutating func appKey(_ app: URL) -> String {
        let p = app.standardizedFileURL.path
        if let k = appKeyCache[p] { return k }
        let k = Bundle(url: app)?.bundleIdentifier ?? p
        appKeyCache[p] = k
        return k
    }

    /// このパスたちを調べ直す（無くなったファイルは外す）
    public mutating func update(_ paths: [String]) {
        let fm = FileManager.default
        for p in paths {
            guard fm.fileExists(atPath: p),
                  let app = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: p)) else {
                byFile[p] = nil; continue
            }
            byFile[p] = appKey(app)
        }
    }

    public mutating func remove(_ paths: [String]) { for p in paths { byFile[p] = nil } }

    /// ファイルの種類（FileCatalog の families。無ければ拡張子）
    static func family(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if let f = FileCatalog.families(name: name, isDir: false).first { return f }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    /// アプリのキー → 種類 → 件数
    public func counts() -> [String: [String: Int]] {
        var out: [String: [String: Int]] = [:]
        for (p, k) in byFile {
            guard let f = OpenWithIndex.family(p) else { continue }
            out[k, default: [:]][f, default: 0] += 1
        }
        return out
    }

    /// グラフの線（アプリのキー, ファイルのパス）
    public var pairs: [(String, String)] { byFile.map { ($0.value, $0.key) } }

    /// 説明文の「いつも開くファイル: PDF（手元に 49 個） 画像（手元に 3 個）」。件数の多い順に top 種類まで
    public static func describe(_ opens: [String: Int], top: Int = 3) -> String {
        let xs = opens.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(top)
        if xs.isEmpty { return "" }
        return "いつも開くファイル: " + xs.map { "\(FileCatalog.familyJP[$0.key] ?? $0.key.uppercased())（手元に \($0.value) 個）" }
            .joined(separator: " ")
    }
}
