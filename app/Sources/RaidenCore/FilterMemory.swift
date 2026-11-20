import Foundation

/// 名前を付けて保存した絞り込み（#仕事のPDF → #ext pdf #path 仕事）。settings.json の savedFilters に入る
public struct SavedFilter: Codable, Equatable, Sendable {
    public var name: String          // 「#」を付けない（仕事のPDF）
    public var commands: [String]    // ["#ext pdf", "#path 仕事"]
    public init(name: String, commands: [String]) { self.name = name; self.commands = commands }

    public var text: String { commands.joined(separator: " ") }

    /// 名前に使えるか。使えなければ理由を返す（コマンドの名前・別名と同じ・空白や / - . を含む・文字で始まらない）
    public static func problem(name raw: String) -> String? {
        let n = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "＃", with: "#")
        let name = n.hasPrefix("#") ? String(n.dropFirst()) : n
        if name.isEmpty { return "名前を入れてください" }
        if name.contains(where: \.isWhitespace) { return "名前に空白は使えません" }
        guard let first = name.first, first.isLetter else { return "名前は文字で始めてください" }
        if name.contains("/") || name.contains("-") || name.contains(".") || name.contains(",") { return "名前に / - . , は使えません" }
        let k = Describe.normalize(name)
        if QueryFilters.aliases.contains(where: { Describe.normalize($0.0) == k })
            || QueryFilters.typeShorthands.contains(where: { $0.0 == k }) || QueryFilters.saveWords.contains(k) {
            return "#\(name) はコマンドの名前なので使えません"
        }
        return nil
    }

    /// 「#保存 名前」などで打った名前から「#」を外す
    public static func clean(_ raw: String) -> String {
        let n = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "＃", with: "#")
        return n.hasPrefix("#") ? String(n.dropFirst()) : n
    }
}

/// 保存した絞り込みの置き場（QueryFilters.parse が「#仕事のPDF」を中身のコマンドに広げるときに引く）。
/// AppDelegate が設定を読んだ・変えたときに入れ直す。検索の列からも読むので鍵をかける
public enum SavedFilters {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var items: [SavedFilter] = []

    public static func set(_ s: [SavedFilter]) { lock.lock(); items = s; lock.unlock() }
    public static var all: [SavedFilter] { lock.lock(); defer { lock.unlock() }; return items }

    /// 名前（「#」なし、大文字小文字・全角半角を揃えて）で引く
    public static func find(_ name: String) -> SavedFilter? {
        let k = Describe.normalize(name)
        return all.first { Describe.normalize($0.name) == k }
    }

    static func hasPrefix(_ name: String) -> Bool {
        let k = Describe.normalize(name)
        return !k.isEmpty && all.contains { Describe.normalize($0.name).hasPrefix(k) }
    }
}

/// 検索の記録（search_log）から覚えた「#」の使い方。入力欄の候補の並びに使う。
///   combos: 使った「#」の組み合わせ（「#ext pdf #path Downloads」）。「#」を打った直後の一覧の先頭に出す
///   values: コマンドごとのよく使う値（値の候補を上に出す）
///   folders: よく使う場所（#path に書いた場所と、選んだファイルの親フォルダ）
///   files: 最近選んだファイル・フォルダ（#with・#near の値の候補）
/// 点数は 1 回ごとに、選んで開いたら 1、選ばずに閉じたら 0.4 を、30 日で半分になるように足す
public struct FilterMemory: Sendable {
    public struct Combo: Sendable, Equatable {
        public let commands: [String]   // 正規の形（#ext pdf）。コマンドの順（kind type ext date … with near）に並べる
        public let score: Double
        public let count: Int
        public let lastUsed: Int
        public var text: String { commands.joined(separator: " ") }
    }

    public var combos: [Combo] = []
    public var values: [QueryFilters.Command: [String: Double]] = [:]   // Describe.normalize した値 → 点数
    public var folders: [String] = []   // よく使う順（絶対パスか、#path に書いた名前）
    public var files: [String] = []     // 新しい順（絶対パス）
    /// 選ばずに閉じた・「見つかりません」だった言い方（コマンドを抜いた言葉、新しい順）。#alias の候補
    public var missed: [String] = []
    public static let empty = FilterMemory()
    public init() {}

    /// 一覧に出す組み合わせの点数の下限（選んで開いた 1 回分より少し下）
    public static let comboMin = 0.8
    static let halfLife = 30.0 * 86400
    static let order: [QueryFilters.Command] = QueryFilters.Command.allCases

    /// 1 つのコマンドの正規の形（#e pdf → #ext pdf、#in "Obsidian Vault" → #path "Obsidian Vault"）
    public static func canonical(_ p: QueryFilters.Parsed) -> String? {
        guard p.ok, let c = p.command, let v = p.value else { return nil }
        return c.name + " " + (v.contains(where: \.isWhitespace) ? "\"\(v)\"" : v)
    }

    public static func build(from log: [SearchLogEntry], now: Date = Date()) -> FilterMemory {
        var m = FilterMemory()
        var combo: [String: (cmds: [String], score: Double, count: Int, last: Int)] = [:]
        var folder: [String: Double] = [:]
        var files: [(String, Int)] = []
        var seenFile = Set<String>()
        var seenMiss = Set<String>()
        let t = now.timeIntervalSince1970
        for e in log {
            let w = (e.chosenRank != nil ? 1.0 : 0.4) * pow(0.5, max(0, t - Double(e.ts)) / halfLife)
            let f = QueryFilters.parse(e.query, now: Date(timeIntervalSince1970: TimeInterval(e.ts)))
            // 同じコマンドは最後の値だけ（#date を書き直した途中の形は数えない）
            var byCmd: [QueryFilters.Command: String] = [:]
            for p in f.parsed { if let c = p.command, let s = canonical(p) { byCmd[c] = s } }
            if !byCmd.isEmpty {
                let cmds = order.compactMap { byCmd[$0] }
                let key = cmds.joined(separator: " ")
                var x = combo[key] ?? (cmds, 0, 0, 0)
                x.score += w; x.count += 1; x.last = max(x.last, e.ts)
                combo[key] = x
                for p in f.parsed where p.ok {
                    guard let c = p.command, let v = p.value else { continue }
                    m.values[c, default: [:]][Describe.normalize(v), default: 0] += w
                    if c == .path {
                        let k = v.hasPrefix("~") || v.hasPrefix("/") ? (v as NSString).expandingTildeInPath : v
                        folder[k.precomposedStringWithCanonicalMapping, default: 0] += w
                    }
                }
            }
            if e.chosenRank == nil && (e.dismissed || e.notFound) {
                let q = f.text.trimmingCharacters(in: .whitespaces)
                if !q.isEmpty && m.missed.count < 12 && seenMiss.insert(Describe.normalize(q)).inserted { m.missed.append(q) }
            }
            if let k = e.chosenKind, let key = e.chosenKey, k == "file" || k == "folder", key.hasPrefix("/") {
                let dir = k == "folder" ? key : (key as NSString).deletingLastPathComponent
                folder[dir, default: 0] += w * 0.5
                if seenFile.insert(key).inserted { files.append((key, e.ts)) }
            }
        }
        m.combos = combo.values.filter { $0.score >= comboMin }
            .map { Combo(commands: $0.cmds, score: $0.score, count: $0.count, lastUsed: $0.last) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.text < $1.text }
        m.folders = folder.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        m.files = files.sorted { $0.1 > $1.1 }.map(\.0)
        return m
    }

    /// 値の点数（候補の insert・別の言い方のどれかが覚えた値と同じなら、その一番大きい点数）
    func use(_ c: QueryFilters.Command, _ forms: [String]) -> Double {
        guard let vs = values[c] else { return 0 }
        return forms.map { vs[Describe.normalize($0)] ?? 0 }.max() ?? 0
    }
}

/// 「#」を打たなくても出す絞り込みの候補（「pdf」→ #ext pdf、「先週」→ #date lastweek）。
/// 入力欄の下に薄く出し、Tab / → で決めたときだけチップにする（勝手には絞らない）
public enum FilterSuggest {
    public struct Suggestion: Sendable, Equatable {
        public let commands: [String]   // チップにするコマンド（保存した名前なら中身の全部）
        public let title: String        // #date lastweek
        public let label: String        // 先週
        public let symbol: String
        public let word: String         // 入力のどの言葉から出したか
        public let range: Range<Int>    // その言葉の位置（文字数）。決めたら入力から外す
    }

    /// 日本語の言葉（入力のどこにあっても当たる）→ (コマンド, 表示)
    static let words: [(String, String, String, String)] = [
        ("今日", "#date today", "今日", "clock"), ("きょう", "#date today", "今日", "clock"),
        ("昨日", "#date yesterday", "昨日", "clock"), ("きのう", "#date yesterday", "昨日", "clock"),
        ("今週", "#date thisweek", "今週", "clock"), ("先週", "#date lastweek", "先週", "clock"),
        ("今月", "#date thismonth", "今月", "clock"), ("先月", "#date lastmonth", "先月", "clock"),
        ("今年", "#date thisyear", "今年", "clock"), ("去年", "#date lastyear", "去年", "clock"), ("昨年", "#date lastyear", "去年", "clock"),
        ("スクリーンショット", "#kind ss", "スクショ", "camera.viewfinder"), ("スクショ", "#kind ss", "スクショ", "camera.viewfinder"),
        ("画像", "#kind image", "画像", "photo"), ("写真", "#kind image", "画像", "photo"),
        ("動画", "#kind movie", "動画", "film"), ("音楽", "#kind music", "音声", "waveform"), ("音声", "#kind music", "音声", "waveform"),
        ("エクセル", "#kind xls", "Excel・表計算", "tablecells"), ("表計算", "#kind xls", "Excel・表計算", "tablecells"),
        ("ワード", "#kind doc", "Word・文書", "doc.text"), ("スライド", "#kind ppt", "スライド", "rectangle.on.rectangle"),
        ("パワポ", "#kind ppt", "スライド", "rectangle.on.rectangle"), ("圧縮", "#kind zip", "圧縮", "archivebox"),
        ("フォルダ", "#type d", "フォルダだけ", "folder"),
        ("ダウンロード", "#path Downloads", "ダウンロード", "folder"), ("デスクトップ", "#path Desktop", "デスクトップ", "folder"),
        ("書類", "#path Documents", "書類", "folder"),
    ]
    /// 英数字の言葉（前後が英数字でないときだけ当たる。大文字小文字は見ない）
    static let asciiWords: [(String, String, String, String)] = [
        ("today", "#date today", "今日", "clock"), ("yesterday", "#date yesterday", "昨日", "clock"),
        ("screenshot", "#kind ss", "スクショ", "camera.viewfinder"),
    ]
    public static let commonExts = ["pdf", "docx", "doc", "xlsx", "xls", "pptx", "ppt", "key", "numbers", "pages", "png", "jpg", "jpeg",
                                    "heic", "gif", "svg", "psd", "md", "txt", "csv", "json", "zip", "mov", "mp4", "mp3", "wav", "html"]
    /// 一度に出す数
    public static let limit = 3

    /// text: 入力欄の文字（チップは含まない）。committed: チップ。すでに同じコマンドがある候補は出さない
    public static func suggest(_ text: String, committed: [String] = [], memory: FilterMemory = .empty,
                               source: FilterSource? = nil) -> [Suggestion] {
        let chars = Array(text)
        if chars.isEmpty { return [] }
        // 「#」で始まるトークンの中は見ない
        // 「#」で始まるトークンと、コマンドならその値のトークンも見ない
        var masked = chars
        var i = 0
        var maskNext = false
        while i < chars.count {
            let atStart = i == 0 || chars[i - 1].isWhitespace
            if atStart && !chars[i].isWhitespace && (QueryFilters.isMark(chars[i]) || maskNext) {
                let isMark = QueryFilters.isMark(chars[i])
                var tok = ""
                while i < chars.count && !chars[i].isWhitespace { tok.append(chars[i]); masked[i] = " "; i += 1 }
                maskNext = isMark && QueryFilters.commandName(tok).flatMap { QueryFilters.command(named: $0) } != nil
            } else { i += 1 }
        }
        let low = masked.map { Character($0.lowercased()) }
        let usedCmds = Set(committed.compactMap { QueryFilters.parse($0).order.first })
        var out: [Suggestion] = []
        var taken: [Range<Int>] = []

        func find(_ w: String, ascii: Bool) -> [Range<Int>] {
            let wc = Array(w.lowercased())
            guard wc.count <= low.count else { return [] }
            var rs: [Range<Int>] = []
            for s in 0...(low.count - wc.count) where Array(low[s..<s + wc.count]) == wc {
                if ascii {
                    let before = s > 0 ? low[s - 1] : " ", after = s + wc.count < low.count ? low[s + wc.count] : " "
                    if (before.isASCII && (before.isLetter || before.isNumber)) || (after.isASCII && (after.isLetter || after.isNumber)) { continue }
                }
                rs.append(s..<s + wc.count)
            }
            return rs
        }
        func add(_ cmds: [String], _ title: String, _ label: String, _ sym: String, _ r: Range<Int>) {
            guard !taken.contains(where: { $0.overlaps(r) }) else { return }
            let cs = cmds.compactMap { QueryFilters.parse($0).order.first }
            if cs.contains(where: usedCmds.contains) { return }
            if out.contains(where: { $0.commands == cmds }) { return }
            // 同じコマンドの候補は 1 つ（「先週」と「今月」が両方あれば後ろの方）
            if cmds.count == 1, let c = cs.first, out.contains(where: { $0.commands.count == 1 && QueryFilters.parse($0.commands[0]).order.first == c }) { return }
            taken.append(r)
            out.append(Suggestion(commands: cmds, title: title, label: label, symbol: sym, word: String(chars[r]), range: r))
        }

        var cands: [([String], String, String, String, Range<Int>)] = []
        // 保存した名前（2 文字以上）
        for sf in SavedFilters.all where sf.name.count >= 2 {
            for r in find(sf.name, ascii: sf.name.allSatisfy(\.isASCII)) { cands.append((sf.commands, "#" + sf.name, sf.text, "bookmark", r)) }
        }
        // 辞書の「#」の条件
        for e in PhraseDictionary.all where e.target == .filter && e.phrase.count >= 2 {
            let cs = e.commands
            if cs.isEmpty { continue }
            for r in find(e.phrase, ascii: e.phrase.allSatisfy(\.isASCII)) { cands.append((cs, cs.joined(separator: " "), "辞書", "book", r)) }
        }
        // 長い言葉を先に（「スクリーンショット」を「スクショ」より先に見る）
        for (w, c, l, sym) in words.sorted(by: { $0.0.count > $1.0.count }) {
            for r in find(w, ascii: false) { cands.append(([c], c, l, sym, r)) }
        }
        for (w, c, l, sym) in asciiWords { for r in find(w, ascii: true) { cands.append(([c], c, l, sym, r)) } }
        var exts = commonExts
        for (e, _) in source?.topExtensions(within: QueryFilters(), limit: 30) ?? [] where !exts.contains(e) && e.count >= 2 { exts.append(e) }
        for e in exts { for r in find(e, ascii: true) { cands.append((["#ext \(e)"], "#ext \(e)", "." + e + " だけ", "tag", r)) } }
        // よく使う場所の名前（2 文字以上）
        for f in memory.folders.prefix(20) {
            let name = (f as NSString).lastPathComponent
            guard name.count >= 2 else { continue }
            let v = f.hasPrefix("/") ? (f as NSString).abbreviatingWithTildeInPath : f
            let ins = v.contains(where: \.isWhitespace) ? "\"\(v)\"" : v
            for r in find(name, ascii: name.allSatisfy(\.isASCII)) { cands.append((["#path \(ins)"], "#path \(name)", "よく使う場所", "folder", r)) }
        }
        // 後ろ（今打っている言葉）から。同じ位置なら長い言葉
        for c in cands.sorted(by: { $0.4.upperBound != $1.4.upperBound ? $0.4.upperBound > $1.4.upperBound : $0.4.count > $1.4.count }) {
            add(c.0, c.1, c.2, c.3, c.4)
            if out.count >= limit { break }
        }
        return out
    }

    /// 決めたとき: 入力からその言葉（と直後の「の」「で」「に」「から」）を外した文字
    public static func accept(_ s: Suggestion, text: String) -> String {
        var chars = Array(text)
        guard s.range.upperBound <= chars.count else { return text }
        var end = s.range.upperBound
        for p in ["から", "の", "で", "に"] {
            let pc = Array(p)
            if end + pc.count <= chars.count && Array(chars[end..<end + pc.count]) == pc { end += pc.count; break }
        }
        chars.removeSubrange(s.range.lowerBound..<end)
        let t = String(chars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.isEmpty ? "" : t + (text.last?.isWhitespace == true ? " " : "")
    }
}
