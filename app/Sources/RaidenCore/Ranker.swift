import Foundation

/// アプリの並べ方の重み（埋め込みモデルは使わない。どれも文字の一致）
///   名前: 日本語名・英語名・.app の名前の先頭か単語の先頭 prefixBonus、途中 substrBonus、読みのローマ字の 1 文字違いまで fuzzyBonus
///   辞書: 手書きの説明（AppDict）・app-notes.json・README などの材料（AppExtra）・分類・開けるファイルの種類の言葉に、
///         入力の 2 文字の組が入っている割合 × dictWeight
///   記録: 選んだ「入力 → アプリ」の入力と今の入力の 2 文字の組の重なり（Dice）が exampleMin 以上なら × exampleWeight
public struct Mix: Sendable, CustomStringConvertible {
    public var prefixBonus: Float = 0.6, substrBonus: Float = 0.35, fuzzyBonus: Float = 0.3
    public var dictWeight: Float = 0.5
    public var exampleWeight: Float = 0.5
    public var exampleMin: Float = 0.5
    public var useExamples = true
    public init() {}
    public var description: String {
        "名前 \(prefixBonus)/\(substrBonus)/\(fuzzyBonus) 辞書 \(dictWeight) 記録 \(exampleWeight)（\(exampleMin) 以上）\(useExamples ? "" : " 記録なし")"
    }
}

/// 並べる対象（アプリ）の名前・辞書の言葉と、選んだ記録
public struct AppIndex: Sendable {
    public private(set) var names: [[String]] = []     // 正規化した名前（文字一致用）
    public private(set) var romaji: [String] = []      // 名前の読みのローマ字（打ち間違い・ローマ字入力用）
    public private(set) var dict: [Set<String>] = []   // 辞書の言葉の 2 文字の組
    // 選んだ記録（入力文 → アプリの添字と回数）
    public private(set) var exText: [String] = []
    public private(set) var exGrams: [Set<String>] = []
    public private(set) var exLinks: [[(Int, Float)]] = []

    public init() {}
    public var count: Int { names.count }

    public mutating func setItems(names raw: [[String]], dictTexts: [String]) {
        names = raw.map { Array(Set($0.map(Lexical.normalize).filter { !$0.isEmpty })) }
        romaji = raw.map { Lexical.canonRomaji(Lexical.romaji($0.first ?? "")) }
        dict = dictTexts.map(Lexical.grams)
    }

    /// 記録を足す。links は（点の添字, 回数）
    public mutating func addExample(text: String, links: [(Int, Float)]) {
        if let i = exText.firstIndex(of: text) {
            for (t, w) in links {
                if let j = exLinks[i].firstIndex(where: { $0.0 == t }) { exLinks[i][j].1 += w } else { exLinks[i].append((t, w)) }
            }
            return
        }
        exText.append(text); exGrams.append(Lexical.grams(text)); exLinks.append(links)
    }
}

public enum Ranker {
    /// 1 件の名前の文字一致
    static func nameBonus(_ c: AppIndex, _ i: Int, nq: String, rq: String, mix m: Mix) -> Float {
        var best: Float = 0
        for nn in c.names[i] {
            let words = nn.split(whereSeparator: { " -_.".contains($0) })
            if nn.hasPrefix(nq) || words.contains(where: { $0.hasPrefix(nq) }) { best = max(best, m.prefixBonus) }
            else if nn.contains(nq) { best = max(best, m.substrBonus) }
        }
        if best == 0 && m.fuzzyBonus > 0 && rq.count >= 3 && !c.romaji[i].isEmpty {
            let d = Lexical.approxSubstringDistance(rq, in: c.romaji[i])
            if d == 0 || (d == 1 && rq.count >= 4) { best = m.fuzzyBonus * (d == 0 ? 1 : 0.8) }
        }
        return best
    }

    /// 1 件分の点数の内訳
    public struct Parts: Sendable {
        public var name: Float = 0, dict: Float = 0, example: Float = 0, extra: Float = 0
        public var total: Float { name + dict + example + extra }
        /// 名前・辞書・記録のどれかに当たった（「見つからない」でない）
        public var hit: Bool { name > 0 || dict > 0 || example > 0 }
    }

    /// 全部の点の内訳。extra は「いつも開く」「最近使った」の加点（点ごと）
    public static func parts(_ c: AppIndex, query q: String, mix m: Mix, extra: [Float]? = nil) -> [Parts] {
        let n = c.count
        var out = [Parts](repeating: Parts(), count: n)
        let nq = Lexical.normalize(q)
        let asciiQ = nq.allSatisfy { $0.isASCII }
        let rq = asciiQ ? Lexical.canonRomaji(nq.filter { $0.isLetter || $0.isNumber }) : ""
        let nameOK = !nq.isEmpty && !(asciiQ && nq.count < 2)
        let qg = Lexical.grams(q)
        for i in 0..<n {
            if nameOK { out[i].name = nameBonus(c, i, nq: nq, rq: rq, mix: m) }
            if !qg.isEmpty && m.dictWeight > 0 {
                out[i].dict = m.dictWeight * Float(qg.intersection(c.dict[i]).count) / Float(qg.count)
            }
            if let extra, i < extra.count { out[i].extra = extra[i] }
        }
        if m.useExamples && !qg.isEmpty {
            for (g, links) in zip(c.exGrams, c.exLinks) where !g.isEmpty {
                let sim = 2 * Float(qg.intersection(g).count) / Float(qg.count + g.count)
                guard sim >= m.exampleMin else { continue }
                let total = links.reduce(0) { $0 + $1.1 }
                for (t, w) in links where total > 0 && t < n {
                    out[t].example = max(out[t].example, m.exampleWeight * sim * (w / total))
                }
            }
        }
        return out
    }

    /// 上位 limit 件の（添字, 内訳）。allow は入力欄のコマンドの絞り込み。同じ点数なら名前の順
    public static func rank(_ c: AppIndex, query q: String, mix m: Mix, extra: [Float]? = nil, names: [String],
                            limit: Int = 8, allow: [Bool]? = nil) -> [(Int, Parts)] {
        let ps = parts(c, query: q, mix: m, extra: extra)
        let idx = ps.indices.filter { allow?[$0] ?? true }
        let sorted = idx.sorted { a, b in
            let x = ps[a].total, y = ps[b].total
            return x != y ? x > y : names[a] < names[b]
        }
        return sorted.prefix(limit).map { ($0, ps[$0]) }
    }
}

/// 文字の重なり・読み
public enum Lexical {
    public static func normalize(_ s: String) -> String { Describe.normalize(s) }

    /// 辞書・記録の文字の一致に使う 2 文字の組。NFKC・小文字にそろえ（カタカナはそのまま）、空白と記号を除き、
    /// ひらがなだけの組（「やつ」「のと」）は中身が無いので捨てる。1 文字の入力はその 1 文字
    public static func grams(_ s: String) -> Set<String> {
        let t = s.precomposedStringWithCompatibilityMapping.lowercased()
        let cs = Array(t.filter { !$0.isWhitespace && !"_-.・、。,「」()（）:：/!?！？\"'".contains($0) })
        if cs.count == 1 { return isHira(cs[0]) ? [] : [String(cs)] }
        var out = Set<String>()
        if cs.count < 2 { return out }
        for i in 0..<(cs.count - 1) {
            let a = cs[i], b = cs[i + 1]
            if isHira(a) && isHira(b) { continue }
            out.insert(String([a, b]))
        }
        return out
    }

    static func isHira(_ c: Character) -> Bool {
        guard let u = c.unicodeScalars.first?.value else { return false }
        return (0x3041...0x309F).contains(u) || c == "ー"
    }

    /// 日本語の読みをローマ字に（CFStringTokenizer の LatinTranscription。漢字も読む）
    public static func romaji(_ s: String) -> String {
        let cf = s as CFString
        guard let tok = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: CFStringGetLength(cf)),
                                                kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale) else { return "" }
        var out = ""
        while !CFStringTokenizerAdvanceToNextToken(tok).isEmpty {
            if let r = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String {
                out += r
            }
        }
        return out.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// ヘボン式・訓令式・長音の違いを揃える（mitsumori / mitumori、seikyuusho / seikyusyo）
    public static func canonRomaji(_ s: String) -> String {
        var t = s.lowercased().filter { $0.isLetter || $0.isNumber }
        for (a, b) in [("tsu", "tu"), ("shi", "si"), ("chi", "ti"), ("sha", "sya"), ("shu", "syu"), ("sho", "syo"),
                       ("cha", "tya"), ("chu", "tyu"), ("cho", "tyo"), ("ja", "zya"), ("ju", "zyu"), ("jo", "zyo"),
                       ("ji", "zi"), ("fu", "hu"), ("sh", "sy"), ("ch", "ty"), ("ou", "o"), ("uu", "u"), ("aa", "a"),
                       ("ii", "i"), ("ee", "e"), ("oo", "o"), ("nn", "n")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    /// q が t のどこかの部分に「何文字の直しで」一致するか（Sellers のアルゴリズム）
    public static func approxSubstringDistance(_ q: String, in t: String) -> Int {
        let a = Array(q.utf8)
        if a.isEmpty { return 0 }
        if a.count <= 64 {
            var t = t
            return t.withUTF8 { Myers(a).distance($0) }
        }
        return approxSubstringDistanceDP(a, Array(t.utf8))
    }

    /// 前の作り（Sellers の表を 1 列ずつ）。64 バイトを超える入力と、ビット並列の版の確かめ用
    public static func approxSubstringDistanceDP(_ a: [UInt8], _ b: [UInt8]) -> Int {
        if a.isEmpty { return 0 }
        var prev = Array(0...a.count)
        var best = prev[a.count]
        for j in 0..<b.count {
            var cur = [Int](repeating: 0, count: a.count + 1)
            for i in 1...a.count {
                cur[i] = min(prev[i] + 1, cur[i - 1] + 1, prev[i - 1] + (a[i - 1] == b[j] ? 0 : 1))
            }
            best = min(best, cur[a.count])
            prev = cur
        }
        return best
    }
}

/// 部分一致の編集距離（Sellers: 入力 q が t のどこかの部分に何文字の直しで一致するか）をビット並列で（Myers 1999）。
/// 入力は 64 バイトまで。Lexical.approxSubstringDistance と同じ値を返す
struct Myers {
    let m: Int
    private var peq = [UInt64](repeating: 0, count: 256)

    init(_ q: [UInt8]) {
        precondition(q.count <= 64)
        m = q.count
        for (i, b) in q.enumerated() { peq[Int(b)] |= 1 << UInt64(i) }
    }

    /// stopAt 以下になったらそこで返す（それより小さい値は区別しない呼び方のとき）
    func distance(_ t: UnsafeBufferPointer<UInt8>, stopAt: Int = -1) -> Int {
        if m == 0 { return 0 }
        let high: UInt64 = 1 << UInt64(m - 1)
        var pv: UInt64 = .max, mv: UInt64 = 0
        var score = m, best = m
        peq.withUnsafeBufferPointer { pq in
            for c in t {
                let eq = pq[Int(c)]
                let xv = eq | mv
                let xh = (((eq & pv) &+ pv) ^ pv) | eq
                var ph = mv | ~(xh | pv)
                var mh = pv & xh
                if ph & high != 0 { score += 1 } else if mh & high != 0 { score -= 1 }
                ph <<= 1; mh <<= 1
                pv = mh | ~(xv | ph)
                mv = ph & xv
                if score < best { best = score; if best <= stopAt { return } }
            }
        }
        return best
    }
}
