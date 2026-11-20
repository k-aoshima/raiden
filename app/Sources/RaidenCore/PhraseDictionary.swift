import Foundation

/// 辞書の 1 行（言い方 → アプリ / ファイル・フォルダ / 「#」の条件）。settings.json の dictionary に入る。
///   「ネット見るやつ」→ app Safari（key は bundle id か .app のパス）
///   「見積書」→ file ~/Documents/見積書.pdf（key は絶対パス。フォルダも file）
///   「仕事のPDF」→ filter #ext pdf #in ~/Documents/仕事（key がそのままコマンド）
/// 入力（コマンドを抜いた言葉）にその言い方が含まれたら、アプリ・ファイルは候補の先頭（「辞書」の節）に出し、
/// 条件は入力欄の下の候補に出して Tab で決めたときだけチップにする（勝手には絞らない）
public struct DictEntry: Codable, Equatable, Sendable {
    public enum Target: String, Codable, CaseIterable, Sendable {
        case app, file, filter
        public var label: String { ["アプリ", "ファイル・フォルダ", "「#」の条件"][Self.allCases.firstIndex(of: self)!] }
    }
    public var phrase: String
    public var target: Target
    public var key: String
    public var name: String

    public init(phrase: String, target: Target, key: String, name: String = "") {
        self.phrase = phrase.trimmingCharacters(in: .whitespaces)
        self.target = target
        self.key = target == .file ? (key as NSString).expandingTildeInPath.precomposedStringWithCanonicalMapping : key.trimmingCharacters(in: .whitespaces)
        let last = (self.key as NSString).lastPathComponent
        self.name = !name.isEmpty ? name : target == .filter ? self.key : target == .file ? last : (last as NSString).deletingPathExtension
    }

    /// 条件の行のコマンド（#in ~/x → #path ~/x の形にそろえる）。読めない物は外す
    public var commands: [String] {
        guard target == .filter else { return [] }
        let f = QueryFilters.parse(key + " ")
        return f.parsed.compactMap(FilterMemory.canonical)
    }

    /// 足す・直すときに見る。使えなければ理由
    public var problem: String? {
        if Describe.normalize(phrase).isEmpty { return "言い方を入れてください" }
        switch target {
        case .app: return key.isEmpty ? "アプリを選んでください" : nil
        case .file: return key.hasPrefix("/") ? nil : "ファイルかフォルダを選んでください"
        case .filter:
            let f = QueryFilters.parse(key + " ")
            if !f.notes.isEmpty { return f.notes.joined(separator: "、") }
            return commands.isEmpty ? "#ext pdf のように条件を書いてください" : nil
        }
    }
}

/// 辞書の置き場（AppDelegate が設定を読んだ・変えたときに入れ直す）と、入力との一致
public enum PhraseDictionary {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var items: [DictEntry] = []

    public static func set(_ e: [DictEntry]) { lock.lock(); items = e; lock.unlock() }
    public static var all: [DictEntry] { lock.lock(); defer { lock.unlock() }; return items }

    /// 入力にその言い方が含まれる行（コマンドは抜いて見る。大文字小文字・全角半角はそろえる）。
    /// 長い言い方を先に、同じ長さなら辞書の順。entries を渡せば置き場の代わりにそれを見る（確かめ用）
    public static func matches(_ query: String, in entries: [DictEntry]? = nil) -> [DictEntry] {
        let text = QueryFilters.parse(query).text
        let q = Describe.normalize(text).replacingOccurrences(of: " ", with: "")
        if q.isEmpty { return [] }
        let es = entries ?? all
        return es.enumerated().filter { _, e in
            let p = Describe.normalize(e.phrase).replacingOccurrences(of: " ", with: "")
            return !p.isEmpty && q.contains(p)
        }.sorted { a, b in
            let la = a.element.phrase.count, lb = b.element.phrase.count
            return la != lb ? la > lb : a.offset < b.offset
        }.map(\.element)
    }

    /// 足す（入力欄の ⌥Enter・#alias・設定）。同じ言い方の行があれば置き換える（上書きか追加かは聞かない）。
    /// replaced: 置き換えたか
    public static func adding(_ e: DictEntry, to list: [DictEntry]) -> (list: [DictEntry], replaced: Bool) {
        let k = Describe.normalize(e.phrase)
        if let i = list.firstIndex(where: { Describe.normalize($0.phrase) == k }) {
            var l = list
            l[i] = e
            return (l, true)
        }
        return (list + [e], false)
    }
}

public extension SearchResult {
    /// 辞書から出す候補（点数は 1）
    init(dictionary app: AppEntry) { self.init(app: app, score: 1) }
}
