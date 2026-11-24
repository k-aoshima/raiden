import AppKit

// Kodou-ui の土台（~/Project/kodou-ui の tokens.css を AppKit に写したもの）。
// 色・字体・余白・動き・ドット絵のアイコンはここだけで持ち、画面の部品はこの値だけを使う。
// 値を変えたら DESIGN.md（リポジトリの根）も直す。

enum K {
    // MARK: 外観

    /// 外観（設定の「一般 → 外観」）。既定はライト
    static var theme: RaidenTheme = .light
    /// パネル・設定窓に当てる外観
    static var appearance: NSAppearance? {
        switch theme {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    // MARK: 色（tokens.css と同じ値。読ませる色は地に 4.5:1 以上、部品の境界は 3:1 以上）

    static let bg = c(0xF4F4EF, 0x15171C)
    static let panel = c(0xFBFBF8, 0x1A1D23)
    static let fg = c(0x20242B, 0xD9DCE3)
    static let dim = c(0x575B63, 0xA7ACB6)
    static let faint = c(0x666A72, 0x9196A1)
    /// かっこ・罫線・区切り。文字には使わない
    static let deco = c(0xA7AAAF, 0x4B505B)
    /// 入力欄やボタンの枠（3:1）
    static let ui = c(0x84878D, 0x707684)
    static let rule = c(0x20242B, 0xD9DCE3, a: 0.30, ad: 0.28)
    static let ruleSoft = c(0x20242B, 0xD9DCE3, a: 0.12, ad: 0.10)
    /// 反転表示
    static let selBg = c(0x20242B, 0xD9DCE3)
    static let selFg = c(0xF4F4EF, 0x15171C)
    /// 反転した行の補足（selBg の上で 4.5:1 以上）
    static let selDim = c(0xC4C6C9, 0x3B3F47)
    static let red = c(0xBE3F0E, 0xFF9670)
    static let green = c(0x00654A, 0x2FAA80)
    static let yellow = c(0x8A5800, 0xEDBE4F)
    static let blue = c(0x0058A0, 0x72B2FF)
    /// アクセント。Raiden は稲妻の藍（DESIGN.md の「このプロジェクトの前提」）。地に 7.6:1（暗い地 6.7:1）
    static let accent = c(0x3B34D6, 0x9C97FF)
    static let accentHover = c(0x2E28B0, 0xBCB8FF)
    static let accentBg = c(0x3B34D6, 0x9C97FF, a: 0.10, ad: 0.14)
    static let redBg = c(0xBE3F0E, 0xFF9670, a: 0.10, ad: 0.13)
    static let yellowBg = c(0x8A5800, 0xEDBE4F, a: 0.11, ad: 0.12)
    /// 塗った面の上の文字
    static let on = panel

    private static func c(_ light: UInt32, _ dark: UInt32, a: CGFloat = 1, ad: CGFloat? = nil) -> NSColor {
        func rgb(_ v: UInt32, _ alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
        }
        let l = rgb(light, a), d = rgb(dark, ad ?? a)
        return NSColor(name: nil) { ap in ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l }
    }

    /// 層（CALayer）に渡す色。view の外観で解決する（cgColor は外観が変わっても自動では変わらない）
    static func cg(_ color: NSColor, in view: NSView) -> CGColor {
        var out = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { out = color.cgColor }
        return out
    }

    // MARK: 字体

    /// 等幅（同梱の JetBrains Mono）。データ・コマンド・入力欄・名前とパス。
    /// 日本語の字体は指定せず、macOS が選ぶ字体に任せる（Andon の Kodou テーマと同じ）
    static func mono(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "JetBrainsMono-SemiBold" : "JetBrainsMono-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    /// 文（説明・案内）。システムの字体（英字は SF Pro、日本語はヒラギノ角ゴ。Andon の Kodou テーマと同じ）
    static func read(_ size: CGFloat, bold: Bool = false) -> NSFont {
        .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    // MARK: 余白と動き

    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16, s5: CGFloat = 24, s6: CGFloat = 32
    static let tFast = 0.08, tBase = 0.14
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: 部品

    /// キーの札（反転の小さな面に太字の等幅。kodou.css の kbd）＋ 言葉（--dim）を並べた文字列。
    /// 「↩ 開く　⌘↩ Finder」のように、全角空白で区切った「キー 言葉」の組を受け取る
    static func keys(_ s: String, size: CGFloat = 11.5, onSelection: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, part) in s.components(separatedBy: "　").enumerated() {
            let sp = part.split(separator: " ", maxSplits: 1).map(String.init)
            guard !sp.isEmpty else { continue }
            if i > 0 { out.append(NSAttributedString(string: "   ", attributes: [.font: mono(size)])) }
            out.append(NSAttributedString(string: "\u{2009}\(sp[0])\u{2009}", attributes: [
                .font: mono(size, bold: true), .foregroundColor: onSelection ? selBg : selFg,
                .backgroundColor: onSelection ? selFg : selBg]))
            if sp.count > 1 {
                out.append(NSAttributedString(string: " " + sp[1], attributes: [
                    .font: read(size), .foregroundColor: onSelection ? selDim : dim]))
            }
        }
        return out
    }
}

/// 外観の選び方（設定に保存する値）
enum RaidenTheme: String, CaseIterable {
    case light, dark, system
    var label: String {
        switch self {
        case .light: return "ライト"
        case .dark: return "ダーク"
        case .system: return "Mac に合わせる"
        }
    }
}

// MARK: ドット絵のアイコン

/// SF Symbols の名前を受け取り、Kodou-ui のドット絵（12×12 のマス）を返す。テンプレート画像なので contentTintColor で色が付く。
/// size は元の文字の大きさの目安: 18 以上は 1 マス 2pt（24pt）、14 以上は 1.5pt（18pt）、それ未満は 1pt（12pt）
func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
    PixelIcon.image(name, pt: size)
}

enum PixelIcon {
    private static var cache: [String: NSImage] = [:]

    static func glyph(for name: String) -> (rows: [String], tone: Bool) {
        let tone = name.hasSuffix(".fill")
        let base = tone ? String(name.dropLast(5)) : name
        let all = RaidenGlyphs.glyphs.merging(PixelGlyphs.glyphs) { a, _ in a }
        let key = RaidenGlyphs.alias[base] ?? RaidenGlyphs.alias[name] ?? PixelGlyphs.alias[base] ?? PixelGlyphs.alias[name]
            ?? (all[base] != nil ? base : "unknown")
        return (all[key] ?? PixelGlyphs.glyphs["unknown"]!, tone)
    }

    static func cell(pt: CGFloat) -> CGFloat { pt >= 18 ? 2 : pt >= 14 ? 1.5 : 1 }

    static func image(_ name: String, pt: CGFloat = 12) -> NSImage {
        let c = cell(pt: pt)
        let id = "\(name)@\(c)"
        if let i = cache[id] { return i }
        let g = glyph(for: name)
        let i = render(g.rows, tone: g.tone, cell: c)
        i.accessibilityDescription = name
        cache[id] = i
        return i
    }

    static func render(_ rows: [String], tone: Bool, cell c: CGFloat) -> NSImage {
        let grid = rows.map { Array($0) }
        let h = grid.count, w = grid.first?.count ?? 0
        let inside = tone ? interior(grid) : []
        let img = NSImage(size: NSSize(width: CGFloat(w) * c, height: CGFloat(h) * c), flipped: true) { _ in
            NSGraphicsContext.current?.shouldAntialias = false
            if tone {
                NSColor.black.withAlphaComponent(0.32).setFill()
                for (y, x) in inside { NSRect(x: CGFloat(x) * c, y: CGFloat(y) * c, width: c, height: c).fill() }
            }
            NSColor.black.setFill()
            for y in 0..<h {
                var x = 0
                while x < w {
                    guard grid[y][x] == "#" else { x += 1; continue }
                    var e = x
                    while e < w, grid[y][e] == "#" { e += 1 }
                    NSRect(x: CGFloat(x) * c, y: CGFloat(y) * c, width: CGFloat(e - x) * c, height: c).fill()
                    x = e
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// 線の外側から届かないマス（内側）。".fill" の記号はここを薄く塗る
    static func interior(_ g: [[Character]]) -> [(Int, Int)] {
        let h = g.count, w = g.first?.count ?? 0
        var out = Array(repeating: Array(repeating: false, count: w), count: h)
        var stack: [(Int, Int)] = []
        for x in 0..<w { stack.append((0, x)); stack.append((h - 1, x)) }
        for y in 0..<h { stack.append((y, 0)); stack.append((y, w - 1)) }
        while let (y, x) = stack.popLast() {
            guard y >= 0, x >= 0, y < h, x < w, !out[y][x], g[y][x] != "#" else { continue }
            out[y][x] = true
            stack += [(y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)]
        }
        var r: [(Int, Int)] = []
        for y in 0..<h { for x in 0..<w where g[y][x] != "#" && !out[y][x] { r.append((y, x)) } }
        return r
    }
}

/// Raiden で足したドット絵と、Raiden が使う SF Symbols の名前の割り当て
enum RaidenGlyphs {
    static let glyphs: [String: [String]] = [
        "mail": ["............", "############", "##........##", "#.#......#.#", "#..#....#..#", "#...#..#...#",
                 "#....##....#", "#..........#", "#..........#", "############", "............", "............"],
        "tag": ["######......", "#....##.....", "#.##..##....", "#.##...##...", "#.......##..", "##.......##.",
                ".##.......##", "..##.....##.", "...##...##..", "....##.##...", ".....###....", "......#....."],
        "arrowD": ["............", ".....##.....", ".....##.....", ".....##.....", ".....##.....", ".....##.....",
                   ".....##.....", "...#.##.#...", "....####....", "....####....", ".....##.....", "............"],
        "question": ["...######...", "..#......#..", ".#..####..#.", "#..#....#..#", "#.......#..#", "#......#...#",
                     "#.....#....#", "#.....#....#", "#..........#", ".#....#...#.", "..#......#..", "...######..."],
        "minusc": ["...######...", "..#......#..", ".#........#.", "#..........#", "#..........#", "#..######..#",
                   "#..######..#", "#..........#", "#..........#", ".#........#.", "..#......#..", "...######..."],
        "record": ["...######...", "..#......#..", ".#..####..#.", "#..######..#", "#.########.#", "#.########.#",
                   "#.########.#", "#.########.#", "#..######..#", ".#..####..#.", "..#......#..", "...######..."],
        "numlist": ["............", "............", "#...#######.", "#...........", "............", "##..#######.",
                    ".#..........", "#...........", "##..#######.", "............", "............", "............"],
    ]
    static let alias: [String: String] = [
        "app.badge": "square",
        "brain": "sparkle",
        "arrow.down.circle": "arrowD",
        "arrow.down.doc": "file",
        "bookmark": "book",
        "doc.on.clipboard": "copy",
        "envelope": "mail",
        "folder.badge.minus": "folder",
        "line.3.horizontal.decrease": "filterc",
        "list.bullet": "list",
        "list.number": "numlist",
        "lock.shield": "shield",
        "minus.circle": "minusc",
        "pencil.and.outline": "pencil",
        "questionmark.circle": "question",
        "record.circle": "record",
        "rectangle.split.1x2": "stack",
        "square.grid.2x2": "grid",
        "tag": "tag",
        "text.badge.checkmark": "checkc",
        "text.magnifyingglass": "search",
        "bolt.fill": "bolt",
        "raiden.clipboard": "copy",
        "raiden.learn": "book",
        "raiden.preview": "sidebarR",
        "raiden.searchlog": "list",
        "raiden.work": "layers",
    ]
}

// MARK: 罫線の枠

/// パネルの地と罫線の枠（kodou.css の .box）。枠は 1px の線を内側に寄せて引き、左上に名前・右上に状態を線の上に載せる。
/// 名前と状態のラベルは地の色を塗って線を切る（KFrameView.title）
final class KFrameView: NSView {
    static let inset: CGFloat = 6
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        K.panel.setFill()
        bounds.fill()
        let r = bounds.insetBy(dx: Self.inset + 0.5, dy: Self.inset + 0.5)
        K.rule.setStroke()
        let p = NSBezierPath(rect: r)
        p.lineWidth = 1
        p.stroke()
    }

    /// 枠の線の上に載せるラベル（地の色で線を切る）
    static func title(_ s: String = "") -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = K.mono(11.5)
        l.textColor = K.dim
        l.drawsBackground = true
        l.backgroundColor = K.panel
        return l
    }
}

/// 色で塗るだけの面（枠の線を切る地・細い罫線）
final class KFill: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    init(_ color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}
