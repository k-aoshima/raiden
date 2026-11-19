import Foundation

/// アプリの説明文づくりと、名前の文字一致。
public enum Describe {
    static let categories: [String: String] = [
        "utilities": "便利ツール", "productivity": "仕事効率化 書類作成",
        "developer-tools": "開発 プログラミング", "social-networking": "チャット 連絡",
        "music": "音楽 曲を聴く", "video": "動画 映像を見る", "entertainment": "エンタメ",
        "education": "学習", "finance": "お金 帳簿 家計", "business": "ビジネス",
        "board-games": "ゲーム", "games": "ゲーム", "books": "本 読書", "news": "ニュース",
        "reference": "調べもの 辞書", "travel": "地図 旅行 行き方", "photography": "写真",
        "healthcare-fitness": "健康", "graphics-design": "デザイン 絵",
        "lifestyle": "暮らし", "weather": "天気", "sports": "スポーツ",
    ]

    static let docFamilies: [(NSRegularExpression, String)] = [
        ("pdf", "PDF"), ("jpe?g|png|gif|tiff|heic|image", "画像 写真"),
        ("mp3|aac|audio|wav|m4a", "音楽 音声"), ("movie|mp4|mpeg|video|quicktime", "動画"),
        ("plain-text|txt|markdown|\\bmd\\b|rtf", "テキスト"), ("docx?|word", "Word 文書"),
        ("xlsx?|spreadsheet|numbers|csv", "表計算"), ("pptx?|presentation|keynote", "スライド プレゼン"),
        ("html|webarchive|url", "Webページ"), ("source|script|\\.py|swift|header", "プログラム コード"),
        ("zip|archive|tar|gzip", "圧縮ファイル"), ("pages", "文書"), ("epub|ibooks", "電子書籍"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// 日本語名＋英語名＋手書きの説明＋分類＋開けるファイルの種類
    public static func text(_ a: AppEntry, useDict: Bool = true) -> String {
        var s = "\(a.jp) \(a.name)"
        if useDict, let d = appDict[a.bundleID] { s += " " + d }
        if let c = categories[String(a.category.split(separator: ".").last ?? "")] { s += " " + c }
        let d = a.docs.joined(separator: " ").lowercased()
        let range = NSRange(d.startIndex..., in: d)
        var fam: [String] = []
        for (re, w) in docFamilies where re.firstMatch(in: d, range: range) != nil && !fam.contains(w) {
            fam.append(w)
        }
        if !fam.isEmpty { s += " 開けるファイル: " + fam.joined(separator: " ") }
        return s
    }

    /// 文字一致用：NFKC・小文字・カタカナをひらがなに
    public static func normalize(_ s: String) -> String {
        let t = s.precomposedStringWithCompatibilityMapping.lowercased()
            .trimmingCharacters(in: .whitespaces)
        return String(String.UnicodeScalarView(t.unicodeScalars.map { u in
            (0x30A1...0x30F6).contains(u.value) ? Unicode.Scalar(u.value - 0x60)! : u
        }))
    }

    /// 名前の先頭が一致なら prefix、途中に含まれるなら substr を返す
    public static func nameBonus(_ q: String, _ a: AppEntry, prefix: Float, substr: Float) -> Float {
        let nq = normalize(q)
        if nq.isEmpty { return 0 }
        if nq.allSatisfy({ $0.isASCII }) && nq.count < 2 { return 0 }
        var best: Float = 0
        let base = String((a.path as NSString).lastPathComponent.dropLast(4))
        for n in Set([a.jp, a.name, base]) {
            let nn = normalize(n)
            if nn.isEmpty { continue }
            let words = nn.split(whereSeparator: { " -_.".contains($0) })
            if nn.hasPrefix(nq) || words.contains(where: { $0.hasPrefix(nq) }) {
                best = max(best, prefix)
            } else if nn.contains(nq) {
                best = max(best, substr)
            }
        }
        return best
    }
}
