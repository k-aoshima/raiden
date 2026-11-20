import AppKit
import CoreServices
import Foundation

/// 手元のファイル 1 件ずつの「開くアプリ」。NSWorkspace.urlForApplication(toOpen: ファイルの URL) は、
/// Finder の「このアプリケーションで開く」の個別設定があればそれを、無ければ種類の既定を返す。
/// ~/Documents・Downloads・Desktop のファイル（Spotlight で並べる）を、アプリ一覧を作るたびに全部調べる。
///
/// 使い道:
///   - 「PDF を見るやつ」でいつも PDF を開くアプリに足す点（Engine.openBonus）
public struct OpenWithIndex: Sendable {
    /// ファイルのパス → アプリのキー（AppEntry.key と同じ。bundle id、無ければアプリのパス）
    public private(set) var byFile: [String: String] = [:]
    private var appKeyCache: [String: String] = [:]

    public init() {}

    /// 数える場所は ~/Documents・Downloads・Desktop（FileCatalog.defaultRoots）。ファイルの並べ方は Spotlight に聞く（listFiles）
    public static func build(roots: [String] = FileCatalog.defaultRoots, exclude: ScanScope = ScanScope(roots: [])) -> OpenWithIndex {
        var idx = OpenWithIndex()
        idx.update(listFiles(roots: roots, exclude: exclude))
        return idx
    }

    /// roots の中のファイル（フォルダ以外）を Spotlight で並べる。隠し・パッケージの中・.app・除外の名前は除く
    public static func listFiles(roots: [String], exclude: ScanScope) -> [String] {
        let s = SpotlightSearch(exclude: exclude)
        let rs = roots.map(ScanScope.norm).filter { FileManager.default.fileExists(atPath: $0) }
        guard !rs.isEmpty, let q = MDQueryCreate(kCFAllocatorDefault, "kMDItemContentTypeTree == \"public.item\" && kMDItemContentType != \"public.folder\"" as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(q, rs as CFArray, 0)
        MDQuerySetMaxCount(q, 50_000)
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var out: [String] = [], seen = Set<String>()
        for i in 0..<MDQueryGetResultCount(q) {
            guard let raw = MDQueryGetResultAtIndex(q, i) else { continue }
            let item = unsafeBitCast(raw, to: MDItem.self)
            guard let p0 = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let p = p0.precomposedStringWithCanonicalMapping
            guard !s.excluded(p), seen.insert(p).inserted else { continue }
            out.append(p)
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
}
