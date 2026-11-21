import Foundation

/// 「あれ」を探すときの絞り込みの問い（窓の下の端に出す「86 件 · 時期で絞り込む」）。
/// 候補が多いとき、時期・種類・入手元・場所のうち、選ぶと一番よく減る切り口を 1 つ選んで、選び先（コマンドと件数）を 2〜4 個出す。
/// 選び先はふつうのコマンド（#date 先月 など）なので、選んだ結果は打ったときと同じチップになる。
/// 手がかりは候補を減らす力が強いほど効く（Watkins & Watkins 1975、Nairne 2002）ので、残りの件数の見込みが一番小さい切り口を選ぶ
public struct RecallSplit: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public let label: String     // 先月
        public let symbol: String    // SF Symbols
        public let command: String   // #date 先月
        public let count: Int
        public init(label: String, symbol: String, command: String, count: Int) {
            self.label = label; self.symbol = symbol; self.command = command; self.count = count
        }
    }
    public let title: String         // 時期で絞り込む
    public let total: Int
    public let options: [Option]
    public init(title: String, total: Int, options: [Option]) { self.title = title; self.total = total; self.options = options }
}

public enum Recall {
    /// これより少ない候補には問いを出さない（見れば分かる数）
    public static let minTotal = 15
    public static let maxOptions = 4
    /// これ以上の見込み（残りの割合＋取りこぼし）の切り口は聞いても役に立たない
    static let maxScore = 0.75

    /// 時期の選び先（#date の値。上から細かい順）
    static let dateOptions: [(String, String)] = [
        ("today", "今日"), ("今週", "今週"), ("先週", "先週"), ("今月", "今月"), ("先月", "先月"), ("今年", "今年"), ("去年", "去年"),
    ]
    static let kindOptions: [(String, String, String)] = [
        ("pdf", "pdf", "doc.richtext"), ("image", "image", "photo"), ("movie", "movie", "film"), ("audio", "music", "waveform"),
        ("doc", "doc", "doc.text"), ("sheet", "xls", "tablecells"), ("slide", "ppt", "rectangle.on.rectangle"),
        ("text", "text", "text.alignleft"), ("code", "code", "chevron.left.forwardslash.chevron.right"),
        ("archive", "zip", "archivebox"), ("folder", "folder", "folder"),
    ]

    /// entries: 条件に合った全部の候補（並べる前）。f: 今の条件（付いている切り口は聞かない）。hasDate: 言い方から期間を読んだ（「先週の」）
    public static func split(_ entries: [FileEntry], filters f: QueryFilters?, hasDate: Bool = false, now: Date = Date(),
                             projectRoot: (String) -> String = { SpotlightSearch.projectRoot(of: $0) }) -> RecallSplit? {
        let total = entries.count
        guard total >= minTotal else { return nil }
        var cands: [(String, [(RecallSplit.Option, Set<Int>)])] = []

        // 時期
        if !hasDate && (f?.dates.isEmpty ?? true) {
            var opts: [(RecallSplit.Option, Set<Int>)] = []
            for (v, l) in dateOptions {
                guard let (r, _) = QueryFilters.parseDate(v, now: now) else { continue }
                let hit = Set(entries.indices.filter { QueryFilters.dateHit(.date, entries[$0], r) })
                guard !hit.isEmpty, hit.count < total, !opts.contains(where: { $0.1 == hit }) else { continue }
                opts.append((RecallSplit.Option(label: l, symbol: "clock", command: "#date \(v)", count: hit.count), hit))
            }
            cands.append(("時期", pickNested(opts)))
        }
        // 種類
        if f.map({ $0.kinds.isEmpty && $0.kindExts.isEmpty && $0.exts.isEmpty && $0.types.isEmpty }) ?? true {
            var opts: [(RecallSplit.Option, Set<Int>)] = []
            for (fam, v, sym) in kindOptions {
                let hit = Set(entries.indices.filter { fam == "folder" ? entries[$0].isDir : entries[$0].families.contains(fam) })
                guard !hit.isEmpty, hit.count < total else { continue }
                opts.append((RecallSplit.Option(label: QueryFilters.familyLabel[fam] ?? fam, symbol: sym, command: "#kind \(v)", count: hit.count), hit))
            }
            cands.append(("種類", top(opts)))
        }
        // 入手元
        if f?.sources.isEmpty ?? true {
            var opts: [(RecallSplit.Option, Set<Int>)] = []
            for (v, sym) in [("dl", "arrow.down.circle"), ("mail", "envelope"), ("mine", "pencil.and.outline")] {
                let hit = Set(entries.indices.filter { entries[$0].source == v })
                guard !hit.isEmpty, hit.count < total else { continue }
                opts.append((RecallSplit.Option(label: QueryFilters.sourceLabel[v] ?? v, symbol: sym, command: "#src \(v)", count: hit.count), hit))
            }
            cands.append(("入手元", top(opts)))
        }
        // 場所（プロジェクトの根。無ければ親フォルダ）。根を調べる（ファイルを見て回る）のは数の多い親フォルダだけにし、
        // ほかはその根の下にあればまとめ、無ければ親フォルダのまま（数千件で全部調べると 1 秒を超えるため）
        if f.map({ $0.paths.isEmpty && !$0.hasRelation }) ?? true {
            var byDir: [String: [Int]] = [:]
            for (i, e) in entries.enumerated() { byDir[(e.path as NSString).deletingLastPathComponent, default: []].append(i) }
            let busy = byDir.sorted { $0.value.count > $1.value.count }.prefix(rootLookups)
            var roots = Set<String>()
            for (dir, ix) in busy { roots.insert(cachedRoot(dir, path: entries[ix[0]].path, projectRoot)) }
            let sortedRoots = roots.sorted { $0.count > $1.count }   // 深い根を先に
            var groups: [String: Set<Int>] = [:]
            for (dir, ix) in byDir {
                let root = sortedRoots.first { dir == $0 || dir.hasPrefix($0 + "/") } ?? dir
                groups[root, default: []].formUnion(ix)
            }
            let opts = groups.filter { $0.value.count < total }.map { (root, hit) -> (RecallSplit.Option, Set<Int>) in
                let short = (root as NSString).abbreviatingWithTildeInPath
                let v = short.contains(where: \.isWhitespace) ? "\"\(short)\"" : short
                return (RecallSplit.Option(label: placeLabel(root), symbol: "folder", command: "#path \(v)", count: hit.count), hit)
            }
            cands.append(("場所", top(opts)))
        }

        // 残りの件数の見込み（選び先の件数の 2 乗の和 / 全体）＋ どの選び先にも入らない物の割合。小さいほど良い切り口
        var best: (String, [(RecallSplit.Option, Set<Int>)], Double)?
        for (name, opts) in cands where opts.count >= 2 {
            let covered = opts.reduce(into: Set<Int>()) { $0.formUnion($1.1) }.count
            let expect = opts.reduce(0.0) { $0 + Double($1.1.count * $1.1.count) } / Double(total * total)
            let miss = 1 - Double(covered) / Double(total)
            let score = expect + miss
            if best == nil || score < best!.2 { best = (name, opts, score) }
        }
        // どの切り口でも、選んでもほとんど減らない（一番大きい選び先が大半を占める）なら聞かない
        guard let b = best, b.2 < maxScore else { return nil }
        return RecallSplit(title: "\(b.0)で絞り込む", total: total, options: b.1.map(\.0))
    }

    // MARK: - 最近の作業のまとまり

    public struct Session: Sendable {
        public let title: String          // 今日 10:12–11:40 · raiden
        public let items: [FileEntry]
    }

    /// 何も打っていないときに出す、最近の作業のまとまり。最後に使った時刻の順に並べ、gap 秒あいたら別のまとまりにする。
    /// 名前はそのまとまりの日・時刻の幅・一番多い場所（プロジェクトの根）。近い時に使った物は一緒に思い出されやすい（Howard & Kahana 2002）
    public static func sessions(_ entries: [FileEntry], gap: Int = 45 * 60, maxSessions: Int = 3, maxRows: Int = 9, now: Date = Date(),
                                projectRoot: (String) -> String = { SpotlightSearch.projectRoot(of: $0) }) -> [Session] {
        let es = entries.filter { $0.lastUsed > 0 && !$0.name.hasSuffix(".app") }.sorted { $0.lastUsed > $1.lastUsed }
        var groups: [[FileEntry]] = []
        for e in es {
            if let last = groups.last?.last, last.lastUsed - e.lastUsed <= gap { groups[groups.count - 1].append(e) } else { groups.append([e]) }
        }
        var out: [Session] = []
        var rows = 0
        let cal = Calendar.current
        let hm = DateFormatter(); hm.dateFormat = "H:mm"
        let md = DateFormatter(); md.locale = Locale(identifier: "ja_JP"); md.dateFormat = "M/d（E）"
        for g in groups where out.count < maxSessions && rows < maxRows {
            // 1 つのまとまりは多くて 4 行（残りの行を後のまとまりに回す）
            let take = Array(g.prefix(min(4, maxRows - rows)))
            let newest = Date(timeIntervalSince1970: TimeInterval(g.first!.lastUsed))
            let oldest = Date(timeIntervalSince1970: TimeInterval(g.last!.lastUsed))
            let day = cal.isDate(newest, inSameDayAs: now) ? "今日"
                : cal.isDate(newest, inSameDayAs: cal.date(byAdding: .day, value: -1, to: now)!) ? "昨日" : md.string(from: newest)
            let span = g.count == 1 || hm.string(from: oldest) == hm.string(from: newest)
                ? hm.string(from: newest) : "\(hm.string(from: oldest))–\(hm.string(from: newest))"
            var count: [String: Int] = [:]
            for e in g { count[placeLabel(cachedRoot((e.path as NSString).deletingLastPathComponent, path: e.path, projectRoot)), default: 0] += 1 }
            let place = count.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? ""
            out.append(Session(title: "\(day) \(span)" + (place.isEmpty ? "" : " · \(place)"), items: take))
            rows += take.count
        }
        return out
    }

    /// プロジェクトの根を調べる親フォルダの数
    static let rootLookups = 40
    nonisolated(unsafe) static var rootCache: [String: String] = [:]
    static let rootLock = NSLock()
    static func cachedRoot(_ dir: String, path: String, _ f: (String) -> String) -> String {
        rootLock.lock(); let hit = rootCache[dir]; rootLock.unlock()
        if let hit { return hit }
        let r = f(path)
        rootLock.lock(); if rootCache.count > 5000 { rootCache = [:] }; rootCache[dir] = r; rootLock.unlock()
        return r
    }

    /// 場所の名前。「3.3.10」のような版の番号だけの名前は親と並べ、「@」の後ろ（版・ハッシュ）は落とす
    static func placeLabel(_ root: String) -> String {
        var name = (root as NSString).lastPathComponent
        if let at = name.firstIndex(of: "@"), at != name.startIndex { name = String(name[..<at]) }
        if !name.contains(where: \.isLetter) {
            let parent = ((root as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return parent + "/" + name
        }
        return name
    }

    /// 多い順に上位
    static func top(_ opts: [(RecallSplit.Option, Set<Int>)]) -> [(RecallSplit.Option, Set<Int>)] {
        Array(opts.sorted { $0.1.count != $1.1.count ? $0.1.count > $1.1.count : $0.0.label < $1.0.label }.prefix(maxOptions))
    }

    /// 時期は入れ子（今週 ⊂ 今月 ⊂ 今年）なので、細かい順に見て、前に選んだ物とほとんど重なる物は飛ばす
    static func pickNested(_ opts: [(RecallSplit.Option, Set<Int>)]) -> [(RecallSplit.Option, Set<Int>)] {
        var out: [(RecallSplit.Option, Set<Int>)] = []
        var seen = Set<Int>()
        for o in opts {
            let fresh = o.1.subtracting(seen)
            // 新しく増える分が 2 割に満たない（前の選び先でほとんど足りる）なら飛ばす
            guard Double(fresh.count) >= 0.2 * Double(o.1.count) else { continue }
            out.append(o)
            seen.formUnion(o.1)
            if out.count >= maxOptions { break }
        }
        return out
    }
}
