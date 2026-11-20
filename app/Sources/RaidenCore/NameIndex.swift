import Foundation

/// 名前の文字一致を全件ではなく索引で引く（Ranker.nameBonus から使う。結果は全件を 1 件ずつ見たときと同じ）。
///
/// - 名前（正規化した文字列）は UTF-8 のバイトを 1 本に並べ、3 バイトの組（trigram）→ 点の転置索引を作る。
///   入力の 3 バイトの組を全部含む点だけを候補にし、候補だけをバイトで照らし合わせる（先頭・単語の先頭・途中）。
///   UTF-8 はバイトで一致すれば文字の境目でも一致するので、日本語 1 文字（3 バイト）もこの索引で引ける。
///   3 バイトに満たない入力（英数字 2 文字・2 バイトの 1 文字）は、並べたバイトを頭から見る（索引より速い）。
/// - 読みのローマ字は 2 バイトの組（bigram）→ 点の転置索引。打ち間違いを許す一致は q-gram の下限で足切りする:
///   長さ m の入力が k 文字の直しで一致するなら、入力の m-1 個の組のうち少なくとも m-1-2k 個は読みに入っている。
///   足切りを通った点だけ、ビット並列の距離（Myers）で測る。
/// - 1 文字が 1 つのコードポイントでない名前（結合文字・絵文字の組など）は、文字の比べ方とバイトの比べ方がずれうるので
///   索引では見ず、前と同じ比べ方をする（slow）。索引を作った後に名前が変わった点・後ろに足した点も同じ（Corpus.dirty）。
final class NameIndex: @unchecked Sendable {
    /// 索引に入れた点の数（これより後ろの点は前と同じ比べ方）
    let count: Int
    // 名前: 点 d の名前は entry docEntry[d]..<docEntry[d+1]、entry e のバイトは nameBytes[entryStart[e]..<entryStart[e+1]]
    let nameBytes: [UInt8]
    let entryStart: [UInt32]
    let docEntry: [UInt32]
    // 読み: 点 d の読みは romBytes[romStart[d]..<romStart[d+1]]
    let romBytes: [UInt8]
    let romStart: [UInt32]
    // 名前の 3 バイトの組 → 点（keys は昇順、点は gramOffs[k]..<gramOffs[k+1]、各組の中で昇順・重複なし）
    let gramKeys: [UInt32]
    let gramOffs: [UInt32]
    let gramDocs: [UInt32]
    // 読みの 2 バイトの組 → 点（65536 通りを直接引く）
    let romOffs: [UInt32]
    let romDocs: [UInt32]
    /// 索引では見ない点（前と同じ比べ方をする）
    let slow: [Int]
    let buildSeconds: Double

    init(names: [[String]], romaji: [String]) {
        let t0 = Date()
        let n = names.count
        count = n
        var nb: [UInt8] = [], es: [UInt32] = [0], de: [UInt32] = [0]
        var rb: [UInt8] = [], rs: [UInt32] = [0]
        var slowDocs: [Int] = []
        var pairs: [UInt64] = []   // (組 << 32) | 点
        pairs.reserveCapacity(n * 24)
        nb.reserveCapacity(n * 24); rb.reserveCapacity(n * 24)
        for d in 0..<n {
            var simple = true
            for nn in names[d] {
                if nn.unicodeScalars.count != nn.count { simple = false }
                let s = nb.count
                nb.append(contentsOf: nn.utf8)
                es.append(UInt32(nb.count))
                if nb.count - s >= 3 {
                    for p in s..<(nb.count - 2) {
                        let k = UInt64(nb[p]) << 16 | UInt64(nb[p + 1]) << 8 | UInt64(nb[p + 2])
                        pairs.append(k << 32 | UInt64(d))
                    }
                }
            }
            if !simple { slowDocs.append(d) }
            de.append(UInt32(es.count - 1))
            rb.append(contentsOf: romaji[d].utf8)
            rs.append(UInt32(rb.count))
        }
        nameBytes = nb; entryStart = es; docEntry = de
        romBytes = rb; romStart = rs
        slow = slowDocs
        // 名前の組: 並べて重複を除く
        pairs.sort()
        var keys: [UInt32] = [], offs: [UInt32] = [], docs: [UInt32] = []
        docs.reserveCapacity(pairs.count)
        var last: UInt64 = .max
        for x in pairs where x != last {
            last = x
            let k = UInt32(x >> 32)
            if keys.last != k { keys.append(k); offs.append(UInt32(docs.count)) }
            docs.append(UInt32(truncatingIfNeeded: x))
        }
        offs.append(UInt32(docs.count))
        gramKeys = keys; gramOffs = offs; gramDocs = docs
        pairs = []
        // 読みの組: 数えてから詰める（点の順に入れるので各組の中は昇順。同じ点の同じ組は 1 回だけ）
        var cnt = [UInt32](repeating: 0, count: 65537)
        var lastDoc = [Int32](repeating: -1, count: 65536)
        for d in 0..<n {
            let s = Int(rs[d]), e = Int(rs[d + 1])
            guard e - s >= 2 else { continue }
            for p in s..<(e - 1) {
                let g = Int(rb[p]) << 8 | Int(rb[p + 1])
                if lastDoc[g] != Int32(d) { lastDoc[g] = Int32(d); cnt[g + 1] += 1 }
            }
        }
        for g in 0..<65536 { cnt[g + 1] += cnt[g] }
        var fill = Array(cnt[0..<65536])
        var rdocs = [UInt32](repeating: 0, count: Int(cnt[65536]))
        for i in lastDoc.indices { lastDoc[i] = -1 }
        for d in 0..<n {
            let s = Int(rs[d]), e = Int(rs[d + 1])
            guard e - s >= 2 else { continue }
            for p in s..<(e - 1) {
                let g = Int(rb[p]) << 8 | Int(rb[p + 1])
                if lastDoc[g] != Int32(d) { lastDoc[g] = Int32(d); rdocs[Int(fill[g])] = UInt32(d); fill[g] += 1 }
            }
        }
        romOffs = cnt; romDocs = rdocs
        buildSeconds = Date().timeIntervalSince(t0)
    }

    /// 索引の大きさ（バイト）
    var bytes: Int {
        nameBytes.count + romBytes.count + 4 * (entryStart.count + docEntry.count + romStart.count + gramKeys.count + gramOffs.count
            + gramDocs.count + romOffs.count + romDocs.count + slow.count)
    }

    var summary: String {
        String(format: "%d 件 %.2fMB（名前 %.1fMB・名前の組 %d 種 %d 本・読み %.1fMB・読みの組 %d 本）作る %.0fms 索引で見ない点 %d",
               count, Double(bytes) / 1_048_576, Double(nameBytes.count) / 1_048_576, gramKeys.count, gramDocs.count,
               Double(romBytes.count) / 1_048_576, romDocs.count, buildSeconds * 1000, slow.count)
    }

    private func postings(_ key: UInt32) -> Range<Int>? {
        var lo = 0, hi = gramKeys.count
        while lo < hi { let mid = (lo + hi) >> 1; if gramKeys[mid] < key { lo = mid + 1 } else { hi = mid } }
        guard lo < gramKeys.count, gramKeys[lo] == key else { return nil }
        return Int(gramOffs[lo])..<Int(gramOffs[lo + 1])
    }

    /// 入力の 3 バイトの組を全部含む点（昇順）。nil は「索引で絞れない」（3 バイトに満たない）
    private func nameCandidates(_ q: [UInt8]) -> [UInt32]? {
        guard q.count >= 3 else { return nil }
        var ranges: [Range<Int>] = []
        var seen = Set<UInt32>()
        for p in 0..<(q.count - 2) {
            let k = UInt32(q[p]) << 16 | UInt32(q[p + 1]) << 8 | UInt32(q[p + 2])
            guard seen.insert(k).inserted else { continue }
            guard let r = postings(k) else { return [] }
            ranges.append(r)
        }
        ranges.sort { $0.count < $1.count }
        var cand = Array(gramDocs[ranges[0]])
        for r in ranges.dropFirst() {
            if cand.isEmpty { break }
            // 候補が少なければ二分探索、多ければ突き合わせ
            var out: [UInt32] = []
            out.reserveCapacity(cand.count)
            gramDocs.withUnsafeBufferPointer { g in
                if cand.count * 16 < r.count {
                    var lo = r.lowerBound
                    for d in cand {
                        var hi = r.upperBound
                        while lo < hi { let mid = (lo + hi) >> 1; if g[mid] < d { lo = mid + 1 } else { hi = mid } }
                        if lo < r.upperBound && g[lo] == d { out.append(d) }
                    }
                } else {
                    var j = r.lowerBound
                    for d in cand {
                        while j < r.upperBound && g[j] < d { j += 1 }
                        if j < r.upperBound && g[j] == d { out.append(d) }
                    }
                }
            }
            cand = out
        }
        return cand
    }

    @inline(__always) static func isSep(_ b: UInt8) -> Bool { b == 0x20 || b == 0x2D || b == 0x5F || b == 0x2E }

    /// 名前の一致の点数を bonus に書く（索引に入れた点のうち slow でない物だけ。prefix / substr は Mix の値）
    private func fillNames(_ q: [UInt8], prefix: Float, substr: Float, _ bonus: inout [Float]) {
        let qn = q.count
        let qNoSep = !q.contains(where: Self.isSep)
        let cand = nameCandidates(q)
        nameBytes.withUnsafeBufferPointer { nb in entryStart.withUnsafeBufferPointer { es in docEntry.withUnsafeBufferPointer { de in
            q.withUnsafeBufferPointer { qp in
                let q0 = qp[0]
                func score(_ d: Int) -> Float {
                    var best: Float = 0
                    for e in Int(de[d])..<Int(de[d + 1]) {
                        let s = Int(es[e]), len = Int(es[e + 1]) - s
                        if len < qn { continue }
                        var pre = memcmp(nb.baseAddress! + s, qp.baseAddress!, qn) == 0
                        var found = pre
                        if !pre {
                            var p = 1
                            while p <= len - qn {
                                if nb[s + p] == q0 && memcmp(nb.baseAddress! + s + p, qp.baseAddress!, qn) == 0 {
                                    found = true
                                    if qNoSep && Self.isSep(nb[s + p - 1]) { pre = true; break }
                                    if !qNoSep { break }
                                }
                                p += 1
                            }
                        }
                        if pre { best = max(best, prefix) } else if found { best = max(best, substr) }
                    }
                    return best
                }
                if let cand {
                    for d in cand { bonus[Int(d)] = score(Int(d)) }
                } else {
                    // 3 バイトに満たない入力: 頭から全部（名前が入力より短い点はすぐ飛ばす）
                    for d in 0..<count { let b = score(d); if b != 0 { bonus[d] = b } }
                }
            }
        } } }
    }

    /// 読みのローマ字の打ち間違い 1 文字まで（Ranker と同じ: 0 文字違い ×1、入力 4 文字以上なら 1 文字違い ×0.8）。
    /// 名前の一致が無い点（bonus == 0）だけ見る
    private func fillFuzzy(_ rq: [UInt8], fuzzy: Float, _ bonus: inout [Float]) {
        let m = rq.count
        let k = m >= 4 ? 1 : 0
        let need = (m - 1) - 2 * k   // q-gram の下限（m >= 3 なら 1 以上）
        guard m >= 3, need >= 1 else { return }
        let myers: Myers? = m <= 64 ? Myers(rq) : nil
        var cnt = [UInt8](repeating: 0, count: count)
        var touched: [Int32] = []
        romDocs.withUnsafeBufferPointer { rd in
            for p in 0..<(m - 1) {
                let g = Int(rq[p]) << 8 | Int(rq[p + 1])
                for j in Int(romOffs[g])..<Int(romOffs[g + 1]) {
                    let d = Int(rd[j])
                    if cnt[d] == 0 { touched.append(Int32(d)) }
                    if cnt[d] < 255 { cnt[d] += 1 }
                }
            }
        }
        romBytes.withUnsafeBufferPointer { rb in
            for d32 in touched {
                let d = Int(d32)
                guard Int(cnt[d]) >= need, bonus[d] == 0 else { continue }
                let s = Int(romStart[d]), e = Int(romStart[d + 1])
                let t = UnsafeBufferPointer(rebasing: rb[s..<e])
                let dist = myers?.distance(t, stopAt: 0) ?? Lexical.approxSubstringDistanceDP(rq, Array(t))
                if dist == 0 || (dist == 1 && m >= 4) { bonus[d] = fuzzy * (dist == 0 ? 1 : 0.8) }
            }
        }
    }

    /// 索引に入れた点の名前の点数を書く。nq が 1 文字 1 コードポイントでない入力なら false（呼ぶ側が全件を前の比べ方で見る）
    func fill(nq: String, rq: String, mix m: Mix, _ bonus: inout [Float]) -> Bool {
        guard nq.unicodeScalars.count == nq.count else { return false }
        fillNames(Array(nq.utf8), prefix: m.prefixBonus, substr: m.substrBonus, &bonus)
        if m.fuzzyBonus > 0 && rq.count >= 3 { fillFuzzy(Array(rq.utf8), fuzzy: m.fuzzyBonus, &bonus) }
        return true
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
