import Foundation
import UniformTypeIdentifiers

/// ファイルかフォルダ 1 個分（Spotlight の結果。SpotlightSearch.entry）。key はパス。
public struct FileEntry: Sendable, Equatable {
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

    public init(path: String, name: String, parentName: String, isDir: Bool, kind: String, families: [String], size: Int,
                mtime: Int, created: Int, added: Int, lastUsed: Int, usedDays: [Int], downloaded: Bool) {
        self.path = path; self.name = name; self.parentName = parentName; self.isDir = isDir; self.kind = kind
        self.families = families; self.size = size; self.mtime = mtime; self.created = created; self.added = added
        self.lastUsed = lastUsed; self.usedDays = usedDays; self.downloaded = downloaded
    }

    /// 拡張子を除いた名前（フォルダはそのまま）
    public var stem: String { isDir ? name : (name as NSString).deletingPathExtension }
}

/// ファイルの種類（families）の決め方。QueryFilters の #kind と SpotlightSearch が使う
public enum FileCatalog {
    static let home = NSHomeDirectory()

    /// 探す場所（Obsidian Vault は Documents の中だが、Documents を外しても残るよう明示する）
    public static var defaultRoots: [String] {
        ["Documents", "Downloads", "Desktop", "Documents/Obsidian Vault"].map { home + "/" + $0 }
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

    private static var imageExt: [String: Bool] = [:]
    private static let imageExtLock = NSLock()
    /// 拡張子が画像か（UTType を引くのは拡張子ごとに 1 回。保存した一覧を読むとき 16 万回引かない）
    static func isImageExt(_ ext: String) -> Bool {
        imageExtLock.lock()
        if let b = imageExt[ext] { imageExtLock.unlock(); return b }
        imageExtLock.unlock()
        let b = UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
        imageExtLock.lock(); imageExt[ext] = b; imageExtLock.unlock()
        return b
    }

    static func families(name: String, isDir: Bool) -> [String] {
        if isDir { return ["folder"] }
        let ext = (name as NSString).pathExtension.lowercased()
        var f: [String] = []
        if isImageExt(ext) { f.append("image") }
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

}

/// 書き出して読み直す用（raiden-eval）
extension FileEntry: Codable {}
