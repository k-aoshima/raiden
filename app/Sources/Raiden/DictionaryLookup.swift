import AppKit
import RaidenCore

/// 辞書（PhraseDictionary）と画面の候補（Candidate）の行き来。
///   candidates: 入力に言い方が含まれる行のアプリ・ファイルを、候補の先頭の「辞書」の節に出す形にする
///   entry: 選んだ候補を「言い方 → これ」の行にする（⌥Enter と #alias から）
enum DictionaryLookup {
    /// apps: 今のアプリ一覧（bundle id かパスで引く）。無くなったアプリ・ファイルは出さない
    static func candidates(_ query: String, apps: [AppEntry]) -> [Candidate] {
        var out: [Candidate] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for e in PhraseDictionary.matches(query) {
            switch e.target {
            case .app:
                guard let a = apps.first(where: { $0.path == e.key || $0.key == e.key || (!$0.bundleID.isEmpty && $0.bundleID == e.key) }),
                      seen.insert(a.path).inserted else { continue }
                out.append(.app(SearchResult(dictionary: a)))
            case .file:
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: e.key, isDirectory: &isDir), seen.insert(e.key).inserted else { continue }
                out.append(.file(FileResult(file: FileEntry(path: e.key, isDir: isDir.boolValue), score: 1)))
            case .filter:
                continue   // 条件は入力欄の下の候補（FilterSuggest）に出す
            }
        }
        return out
    }

    static func entry(phrase: String, _ c: Candidate) -> DictEntry {
        switch c {
        case .app(let r): return DictEntry(phrase: phrase, target: .app, key: r.app.path, name: r.app.jp)
        case .file(let r): return DictEntry(phrase: phrase, target: .file, key: r.file.path, name: r.file.name)
        }
    }

    /// 足した・置き換えたときに入力欄に出す一言
    static func message(_ e: DictEntry, replaced: Bool) -> String {
        "\(e.phrase) → \(e.name) を" + (replaced ? "置き換えました" : "足しました")
    }
}
