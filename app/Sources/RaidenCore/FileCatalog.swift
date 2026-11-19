import AppKit
import CoreServices
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// ファイルかフォルダ 1 個分。key はパス。
public struct FileEntry: Sendable {
    public let path: String
    public let name: String
    public let parentName: String
    public let isDir: Bool
    public let kind: String        // Spotlight の kMDItemKind（「PDF書類」「PNGイメージ」など日本語）
    public let families: [String]  // 種類で絞る用（image / pdf / movie ...。QueryIntent と同じ名前）
    public let size: Int
    public let mtime: Int          // 変更日
    public let created: Int        // 作成日
    public let added: Int          // このフォルダに入った日（kMDItemDateAdded。ダウンロード日もこれ）
    public let lastUsed: Int       // kMDItemLastUsedDate（無ければ 0）
    public let usedDays: [Int]     // kMDItemUsedDates（その土地の日付の通し番号）
    public let downloaded: Bool    // kMDItemWhereFroms があるか ~/Downloads の中

    /// 拡張子を除いた名前（フォルダはそのまま）
    public var stem: String { isDir ? name : (name as NSString).deletingPathExtension }
}

public enum FileCatalog {
    static let home = NSHomeDirectory()

    /// 探す場所（Obsidian Vault は Documents の中だが、Documents を外しても残るよう明示する）
    public static var defaultRoots: [String] {
        ["Documents", "Downloads", "Desktop", "Documents/Obsidian Vault"].map { home + "/" + $0 }
    }

    static let skipDirs: Set<String> = ["node_modules", ".venv", "venv", "__pycache__", ".git", "DerivedData", "Pods"]

    /// 一覧を作る。隠しファイル・パッケージの中・アプリ本体・node_modules などは除く。roots 自体は点にしない。
    public static func collect(roots: [String] = defaultRoots) -> [FileEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
                                      .creationDateKey, .addedToDirectoryDateKey]
        var seen = Set(roots)
        var out: [FileEntry] = []
        let tz = TimeInterval(TimeZone.current.secondsFromGMT())
        for root in roots {
            guard let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in en {
                let path = url.path.precomposedStringWithCanonicalMapping  // 名前は NFD のことがあるので NFC に揃える
                let name = url.lastPathComponent
                let rv = try? url.resourceValues(forKeys: Set(keys))
                let isDir = (rv?.isDirectory ?? false) && !(rv?.isPackage ?? false)
                if skipDirs.contains(name) || name.hasSuffix(".app") {
                    if rv?.isDirectory == true { en.skipDescendants() }
                    continue
                }
                if seen.contains(path) { if isDir { en.skipDescendants() }; continue }
                seen.insert(path)
                var kind = isDir ? "フォルダ" : "書類"
                var lastUsed = 0, used: [Int] = [], added = Int(rv?.addedToDirectoryDate?.timeIntervalSince1970 ?? 0)
                var froms = false
                if let it = MDItemCreate(nil, url.path as CFString) {
                    if let k = MDItemCopyAttribute(it, kMDItemKind) as? String, !k.isEmpty { kind = k }
                    if let d = MDItemCopyAttribute(it, kMDItemLastUsedDate) as? Date { lastUsed = Int(d.timeIntervalSince1970) }
                    if let ds = MDItemCopyAttribute(it, "kMDItemUsedDates" as CFString) as? [Date] {
                        used = ds.map { Int(($0.timeIntervalSince1970 + tz) / 86400) }
                    }
                    if let d = MDItemCopyAttribute(it, "kMDItemDateAdded" as CFString) as? Date, added == 0 {
                        added = Int(d.timeIntervalSince1970)
                    }
                    if let w = MDItemCopyAttribute(it, kMDItemWhereFroms) as? [String], !w.isEmpty { froms = true }
                }
                out.append(FileEntry(
                    path: path, name: name.precomposedStringWithCanonicalMapping,
                    parentName: url.deletingLastPathComponent().lastPathComponent.precomposedStringWithCanonicalMapping,
                    isDir: isDir, kind: kind.precomposedStringWithCanonicalMapping,
                    families: families(name: name, isDir: isDir), size: rv?.fileSize ?? 0,
                    mtime: Int(rv?.contentModificationDate?.timeIntervalSince1970 ?? 0),
                    created: Int(rv?.creationDate?.timeIntervalSince1970 ?? 0),
                    added: added, lastUsed: lastUsed, usedDays: used,
                    downloaded: froms || path.hasPrefix(home + "/Downloads/")))
            }
        }
        return out
    }

    // MARK: - 種類

    static let extFamily: [String: String] = [
        "pdf": "pdf", "mov": "movie", "mp4": "movie", "m4v": "movie", "webm": "movie",
        "xlsx": "sheet", "xls": "sheet", "csv": "sheet", "numbers": "sheet",
        "docx": "doc", "doc": "doc", "pages": "doc", "rtf": "doc",
        "pptx": "slide", "key": "slide",
        "md": "text", "txt": "text",
        "ttf": "font", "otf": "font",
        "zip": "archive", "rar": "archive", "7z": "archive", "dmg": "archive",
        "html": "web", "htm": "web",
        "json": "json",
        "psd": "design", "ai": "design", "svg": "design", "fig": "design",
        "stl": "3d", "glb": "3d", "3dm": "3d", "blend": "3d", "obj": "3d", "moc3": "3d",
        "mp3": "audio", "m4a": "audio", "wav": "audio",
        "py": "code", "swift": "code", "js": "code", "css": "code", "c": "code", "h": "code", "cpp": "code",
    ]

    static func families(name: String, isDir: Bool) -> [String] {
        if isDir { return ["folder"] }
        let ext = (name as NSString).pathExtension.lowercased()
        var f: [String] = []
        if let t = UTType(filenameExtension: ext), t.conforms(to: .image) { f.append("image") }
        if let x = extFamily[ext] { f.append(x) }
        let n = name.precomposedStringWithCanonicalMapping.lowercased()
        if f.contains("image") && (n.contains("スクリーンショット") || n.contains("screenshot")) { f.append("screenshot") }
        return f
    }

    static let familyJP: [String: String] = [
        "image": "画像", "screenshot": "スクリーンショット", "pdf": "PDF", "movie": "動画", "sheet": "表計算",
        "doc": "文書", "slide": "スライド", "text": "テキスト メモ", "font": "フォント", "archive": "圧縮ファイル",
        "web": "Webページ", "json": "設定データ", "design": "デザインデータ", "3d": "3Dモデル", "audio": "音声",
        "code": "プログラム", "folder": "フォルダ",
    ]

    // MARK: - 説明文

    /// Spotlight の種類名が「書類」としか出ない拡張子の言い換え（日本語＋英語）
    static let extHint: [String: String] = [
        "ovpn": "VPN 接続設定 OpenVPN", "dmg": "インストーラ ディスクイメージ installer", "3dm": "Rhino 3Dモデル",
        "moc3": "Live2D モデル", "psd": "Photoshop 画像 レイヤー", "ai": "Illustrator デザイン", "json": "JSON データ 設定",
        "glb": "3Dモデル", "stl": "3Dモデル 3Dプリント", "blend": "Blender 3D", "virtualhime": "Live2D 設定",
        "fzb": "Fritzing パーツ", "fzp": "Fritzing パーツ", "plist": "設定 plist", "bak": "バックアップ",
        "rar": "圧縮ファイル", "zip": "圧縮ファイル", "ttf": "フォント", "otf": "フォント",
        "pdf": "PDF document", "xlsx": "Excel spreadsheet", "xls": "Excel spreadsheet", "docx": "Word document",
        "png": "image", "jpg": "photo image", "jpeg": "photo image", "mov": "video screen recording", "csv": "CSV spreadsheet",
    ]

    /// 中身を読まない分の説明文（これと日付・大きさで「変わったか」を見る）
    public static func baseDescription(_ e: FileEntry, children: [FileEntry]) -> String {
        if e.isDir {
            var counts: [String: Int] = [:]
            for c in children { counts[c.isDir ? "フォルダ" : c.kind, default: 0] += 1 }
            let summary = counts.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \($0.value)個" }.joined(separator: " ")
            let names = children.map(\.stem).sorted().prefix(10).map { String($0.prefix(24)) }.joined(separator: " ")
            return "\(e.name) フォルダ 場所: \(e.parentName) 中身: \(summary) 名前: \(names)"
        }
        let fam = e.families.compactMap { familyJP[$0] }.joined(separator: " ")
        let lower = e.name.lowercased()
        var hint = extHint[(e.name as NSString).pathExtension.lowercased()] ?? ""
        if lower.hasSuffix(".exp3.json") { hint = "Live2D 表情" } else if lower.hasSuffix(".motion3.json") { hint = "Live2D モーション" }
        return "\(e.stem) 種類: \(e.kind) \(fam) \(hint) 場所: \(e.parentName)フォルダ"
    }

    /// 文書と PDF の中身の頭（PDF は PDFKit、テキスト・md・csv・html はそのまま、docx は AppKit）
    public static func content(_ e: FileEntry, limit: Int = 260) -> String {
        if e.isDir { return "" }
        let ext = (e.name as NSString).pathExtension.lowercased()
        let url = URL(fileURLWithPath: e.path)
        var s = ""
        switch ext {
        case "pdf":
            if let doc = PDFDocument(url: url) {
                for i in 0..<min(doc.pageCount, 3) {
                    s += (doc.page(at: i)?.string ?? "") + " "
                    if s.count > limit * 2 { break }
                }
            }
        case "txt", "md", "csv", "html", "htm":
            guard let h = FileHandle(forReadingAtPath: e.path) else { return "" }
            let d = h.readData(ofLength: 8192)
            try? h.close()
            s = String(decoding: d, as: UTF8.self)
            if ext.hasPrefix("htm") {
                s = s.replacingOccurrences(of: "<(script|style)[\\s\\S]*?</\\1>", with: " ", options: .regularExpression)
                s = s.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            }
            if ext == "md" {
                s = s.replacingOccurrences(of: "^---[\\s\\S]*?\\n---", with: " ", options: .regularExpression)
            }
        case "docx":
            if e.size < 5_000_000, let a = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil) {
                s = String(a.string.prefix(limit * 3))
            }
        default:
            return ""
        }
        s = s.replacingOccurrences(of: "[#*`>|\\-=_\\[\\]()]+", with: " ", options: .regularExpression)
        s = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(s.prefix(limit))
    }

    /// 親フォルダのパス → 中の物
    public static func childrenMap(_ entries: [FileEntry]) -> [String: [FileEntry]] {
        var m: [String: [FileEntry]] = [:]
        for e in entries { m[(e.path as NSString).deletingLastPathComponent, default: []].append(e) }
        return m
    }

    // MARK: - 線

    /// contains（フォルダ → 中の物）。添字の組
    public static func containsEdges(_ entries: [FileEntry]) -> [(Int, Int)] {
        let idx = Dictionary(entries.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
        return entries.enumerated().compactMap { i, e in
            idx[(e.path as NSString).deletingLastPathComponent].map { ($0, i) }
        }
    }

    /// co_used（同じ日に使われた物どうし。kMDItemUsedDates は日単位）。weight は同じ日に使った回数。
    /// 1 日に maxGroup 個より多く使われた日は「まとめて開いただけ」とみなして数えない。
    public static func coUsedEdges(_ entries: [FileEntry], maxGroup: Int = 15) -> [(Int, Int, Float)] {
        var byDay: [Int: [Int]] = [:]
        for (i, e) in entries.enumerated() { for d in Set(e.usedDays) { byDay[d, default: []].append(i) } }
        var w: [Int64: Float] = [:]
        for (_, items) in byDay where items.count >= 2 && items.count <= maxGroup {
            for a in items { for b in items where a < b { w[Int64(a) << 32 | Int64(b), default: 0] += 1 } }
        }
        return w.map { (Int($0.key >> 32), Int($0.key & 0xffffffff), $0.value) }
    }

    /// co_time（変更日か追加日が window 秒以内の物どうし。使った日時は 130 件ほどしか入っていないので、その代わり）。
    /// 同じ親フォルダの中どうしは contains で足りるので張らない。window の中に maxGroup 個より多い塊（まとめてコピーした等）は数えない。
    public static func coTimeEdges(_ entries: [FileEntry], window: Int = 1800, maxGroup: Int = 8) -> [(Int, Int, Float)] {
        var ev: [(Int, Int)] = []   // (時刻, 添字)
        for (i, e) in entries.enumerated() where !e.isDir {
            for t in Set([e.mtime, e.added, e.lastUsed]) where t > 0 { ev.append((t, i)) }
        }
        ev.sort { $0.0 < $1.0 }
        let parent = entries.map { ($0.path as NSString).deletingLastPathComponent }
        var w: [Int64: Float] = [:]
        var lo = 0
        for hi in 0..<ev.count {
            while ev[hi].0 - ev[lo].0 > window { lo += 1 }
            let group = Set(ev[lo...hi].map(\.1))
            if group.count > maxGroup { continue }
            let b = ev[hi].1
            for a in group where a != b && parent[a] != parent[b] {
                let key = Int64(min(a, b)) << 32 | Int64(max(a, b))
                w[key] = 1
            }
        }
        return w.map { (Int($0.key >> 32), Int($0.key & 0xffffffff), $0.value) }
    }
}
