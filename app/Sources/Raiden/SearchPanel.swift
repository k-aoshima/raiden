import AppKit
import QuartzCore
import RaidenCore

/// 入力欄を持てる枠なしパネル
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// パネルの色。OS がダークモードでもライトの見た目（白基調）にする
enum PanelStyle {
    static let appearance = NSAppearance(named: .aqua)!
    static let text = NSColor(white: 0.13, alpha: 1)        // 濃いグレー
    static let subText = NSColor(white: 0.42, alpha: 1)
    static let faint = NSColor(white: 0.55, alpha: 1)
    /// 透け具合（設定の「一般 → 透明度」。0 = 白い、0.9 = いちばん透ける。既定 0.6）
    static var transparency = RaidenSettings.defaultTransparency
    /// ガラスの白寄りの色: 不透明度 0.65 ×（1 − 透け具合）。既定 0.6 で 0.26（前は 0.55 固定）
    static var glassTint: NSColor { NSColor(white: 1, alpha: CGFloat(0.65 * (1 - transparency))) }
    /// ガラスの上に重ねる白い面: 不透明度 0.75 ×（1 − 透け具合）。既定 0.6 で 0.30（前は 0.62 固定）
    static var veil: NSColor { NSColor(white: 1, alpha: CGFloat(0.75 * (1 - transparency))) }
    /// これ以上透けさせるときはガラスを .clear にする
    static let clearGlassAbove = 0.75
    /// Raiden の色（アイコンの稲妻の藍）
    static let indigo = NSColor(srgbRed: 0.231, green: 0.204, blue: 0.839, alpha: 1)      // #3B34D6
    static let indigoDeep = NSColor(srgbRed: 0.165, green: 0.141, blue: 0.659, alpha: 1)  // #2A24A8 選んだ行の名前
    static let indigoLabel = NSColor(srgbRed: 0.31, green: 0.29, blue: 0.69, alpha: 1)    // 節の見出し
    /// 入力欄のカーソル・変換中の下線（藍）
    static let caret = indigo
    static let selection = NSColor(srgbRed: 0.231, green: 0.204, blue: 0.839, alpha: 0.10)
    /// 絞り込みの札（効いている物）の面
    static let pillFill = NSColor(srgbRed: 0.231, green: 0.204, blue: 0.839, alpha: 0.09)
    static let separator = NSColor(white: 0, alpha: 0.08)
    static let radius: CGFloat = 22
}

/// SF Symbols の画像
func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

/// 白い面（ガラスの上に重ねる。draw で描くので PNG に書き出しても出る）
final class VeilView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        PanelStyle.veil.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: PanelStyle.radius, yRadius: PanelStyle.radius).fill()
        NSColor(white: 0, alpha: 0.06).setStroke()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: PanelStyle.radius, yRadius: PanelStyle.radius)
        p.lineWidth = 1
        p.stroke()
    }
}

/// 入力欄の下の光る藍の線（両端は消えていく。藍から紫へ、薄い光をまとう）
final class GlowLineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let line = NSRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2)
        let g = NSGradient(colorsAndLocations:
            (NSColor(srgbRed: 0.231, green: 0.204, blue: 0.839, alpha: 0), 0),
            (NSColor(srgbRed: 0.231, green: 0.204, blue: 0.839, alpha: 1), 0.18),
            (NSColor(srgbRed: 0.416, green: 0.298, blue: 0.941, alpha: 1), 0.6),
            (NSColor(srgbRed: 0.416, green: 0.298, blue: 0.941, alpha: 0), 1))
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor(srgbRed: 0.35, green: 0.27, blue: 0.94, alpha: 0.55)
        sh.shadowBlurRadius = 5
        sh.shadowOffset = .zero
        sh.set()
        NSColor(srgbRed: 0.33, green: 0.25, blue: 0.9, alpha: 0.35).setFill()
        NSBezierPath(roundedRect: line.insetBy(dx: bounds.width * 0.2, dy: 0), xRadius: 1, yRadius: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
        g?.draw(in: NSBezierPath(roundedRect: line, xRadius: 1, yRadius: 1), angle: 0)
    }
}

/// 入力欄の編集部品。変換中の文字の下線を藍にする（日本語入力が付ける線の太さはそのまま、色だけ変える）
final class BandFieldEditor: NSTextView {
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let m: NSMutableAttributedString
        if let a = string as? NSAttributedString { m = NSMutableAttributedString(attributedString: a) }
        else { m = NSMutableAttributedString(string: string as? String ?? "") }
        let all = NSRange(location: 0, length: m.length)
        if m.length > 0 {
            var hasLine = false
            m.enumerateAttribute(.underlineStyle, in: all) { v, _, _ in if v != nil { hasLine = true } }
            if !hasLine { m.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: all) }
            m.addAttribute(.underlineColor, value: PanelStyle.caret, range: all)
        }
        super.setMarkedText(m, selectedRange: selectedRange, replacementRange: replacementRange)
    }
}

/// 1 px の区切り線
final class HairlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        PanelStyle.separator.setFill()
        bounds.fill()
    }
}

/// 候補 1 行（アイコン・名前・場所）。選択中は面の色だけで示す（左端の縦線や帯は使わない）。
/// 操作の手がかり（↩ 開く・⌘↩ Finder）は選択中の行の右に小さく出す。
final class ResultRow: NSView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let sub = NSTextField(labelWithString: "")
    let hint = NSTextField(labelWithString: "")
    /// 見出しの右に小さく添える文字（「#」の一覧のコマンド名 #date #k）。藍・等幅
    let tagLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    var selected = false {
        didSet { needsDisplay = true; hint.isHidden = !selected; title.textColor = selected ? PanelStyle.indigoDeep : PanelStyle.text }
    }

    /// 操作の手がかり。キー（↩ ⌘↩ など）は藍、言葉は薄いグレー
    func setHint(_ s: String) {
        let out = NSMutableAttributedString()
        for (i, part) in s.components(separatedBy: "　").enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "　　", attributes: [.font: NSFont.systemFont(ofSize: 11)])) }
            let sp = part.split(separator: " ", maxSplits: 1).map(String.init)
            guard !sp.isEmpty else { continue }   // 空の区切り（ヒントが空・「　」で始まる）で落ちないように
            out.append(NSAttributedString(string: sp[0], attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: PanelStyle.indigo]))
            if sp.count > 1 {
                out.append(NSAttributedString(string: " " + sp[1], attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: PanelStyle.faint]))
            }
        }
        hint.attributedStringValue = out
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = PanelStyle.text
        title.lineBreakMode = .byTruncatingTail
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = PanelStyle.subText
        sub.lineBreakMode = .byTruncatingMiddle
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = PanelStyle.faint
        hint.isHidden = true
        tagLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        tagLabel.textColor = PanelStyle.indigo
        tagLabel.lineBreakMode = .byTruncatingTail
        for v in [icon, title, sub, hint, tagLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        tagLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30), icon.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -10),
            tagLabel.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            tagLabel.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            tagLabel.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -10),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -10),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        PanelStyle.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 10, yRadius: 10).fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    /// マウスを乗せたら選ぶ（プレビューを出すため）
    var onHover: (() -> Void)?
    private var tracking: NSTrackingArea?
    /// 前にマウスで選んだときのマウスの位置。行を作り直しただけ（マウスは動いていない）の入りは無視する
    private static var lastMouse = NSPoint(x: -1, y: -1)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered() }
    override func mouseMoved(with event: NSEvent) { if !selected { hovered() } }

    private func hovered() {
        let p = NSEvent.mouseLocation
        guard p != Self.lastMouse else { return }
        Self.lastMouse = p
        onHover?()
    }
}

/// アイコンと文字の 1 行（節の見出し・「見つかりません」）。選べない
final class LabelLine: NSView {
    init(_ text: String, symbol name: String, detail: String? = nil, big: Bool = false) {
        super.init(frame: .zero)
        let glyph = NSImageView(image: symbol(name, size: big ? 15 : 10, weight: .semibold) ?? NSImage())
        glyph.contentTintColor = big ? PanelStyle.subText : PanelStyle.indigoLabel
        let label = NSTextField(labelWithString: text)
        label.font = big ? .systemFont(ofSize: 14, weight: .semibold) : .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = big ? PanelStyle.text : PanelStyle.indigoLabel
        var views: [NSView] = [glyph, label]
        let d = NSTextField(labelWithString: detail ?? "")
        d.font = .systemFont(ofSize: 11)
        d.textColor = PanelStyle.faint
        if detail != nil { views.append(d) }
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: big ? 22 : 20),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor, constant: big ? 0 : 1),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: big ? 10 : 6),
            label.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
        ])
        if detail != nil {
            NSLayoutConstraint.activate([
                d.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
                d.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 候補 1 件。アプリかファイル・フォルダ
enum Candidate {
    case app(SearchResult)
    case file(FileResult)
    case clip(ClipItem)

    var path: String {
        switch self {
        case .app(let r): return r.app.path
        case .file(let r): return r.file.path
        case .clip: return ""
        }
    }
}

/// 画面に出す 1 行分。candidate が nil の行は見本（PNG の書き出し用）
struct RowItem {
    var candidate: Candidate?
    var title: String
    var sub: String
    var iconPath: String?
    var iconImage: NSImage?
    var hint: String
    /// 見出しの右に小さく添える文字（「#」の一覧のコマンド名）
    var tag = ""
    /// 右のプレビューに出す物（nil は出さない）
    var preview: PreviewTarget?

    init(_ c: Candidate) {
        candidate = c
        iconPath = c.path
        switch c {
        case .app(let r):
            title = r.app.jp == r.app.name ? r.app.jp : "\(r.app.jp)  \(r.app.name)"
            sub = (r.app.path as NSString).abbreviatingWithTildeInPath
            hint = RowItem.appHint
            preview = .app(title: title, path: r.app.path)
        case .file(let r):
            title = r.file.name
            sub = RowItem.shortParent(r.file.path) + RowItem.fileContext(r.file)
            hint = r.file.isDir ? RowItem.folderHint : RowItem.fileHint
            preview = .file(r.file.path)
        case .clip(let c):
            title = c.oneLine
            sub = RowItem.clipSub(c)
            iconPath = RowItem.appPath(c.source.bundleID)
            hint = RowItem.clipHint
            preview = .clip(c)
        }
    }

    /// 「Safari（窓の名前）· 3分前  → メモ、Slack」
    static func clipSub(_ c: ClipItem) -> String {
        var s = c.source.app.isEmpty ? "不明なアプリ" : c.source.app
        if !c.source.title.isEmpty { s += "「\(c.source.title)」" }
        s += " · " + ago(c.source.at)
        var dest: [String] = []
        for p in c.pastes where !p.app.isEmpty && !dest.contains(p.app) { dest.append(p.app) }
        if !dest.isEmpty { s += "  → " + dest.prefix(3).joined(separator: "、") }
        return s
    }

    /// 行の下に添える「いつ・どこから」（ · 10/12 ダウンロード · example.co.jp / · 昨日 開いた / · 11/3 変更）
    static func fileContext(_ e: FileEntry, now: Date = Date()) -> String {
        func day(_ t: Int) -> String { dayText(Date(timeIntervalSince1970: TimeInterval(t)), now: now) }
        if e.source == "mail" { return e.added > 0 ? "  ·  \(day(e.added)) メール添付" : "  ·  メール添付" }
        if e.source == "dl" {
            var s = e.added > 0 ? "  ·  \(day(e.added)) ダウンロード" : "  ·  ダウンロード"
            if !e.origin.isEmpty { s += "  ·  " + e.origin }
            return s
        }
        if e.lastUsed > 0 && e.lastUsed >= e.mtime { return "  ·  \(day(e.lastUsed)) 開いた" }
        if e.mtime > 0 { return "  ·  \(day(e.mtime)) 変更" }
        return ""
    }

    /// 「今日」「昨日」「11/14」「2025/11/14」（去年より前は年も）
    static func dayText(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "今日" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "昨日" }
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = cal.component(.year, from: d) == cal.component(.year, from: now) ? "M/d" : "yyyy/M/d"
        return f.string(from: d)
    }

    static func appPath(_ bundleID: String) -> String? {
        guard !bundleID.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    }

    /// 「たった今」「3分前」「2時間前」「昨日」「11/14」
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return "たった今" }
        if s < 3600 { return "\(s / 60)分前" }
        if Calendar.current.isDateInToday(d) { return "\(s / 3600)時間前" }
        if Calendar.current.isDateInYesterday(d) { return "昨日" }
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M/d"
        return f.string(from: d)
    }

    init(title: String, sub: String, iconPath: String? = nil, iconImage: NSImage? = nil, hint: String, preview: PreviewTarget? = nil) {
        self.title = title; self.sub = sub; self.iconPath = iconPath; self.iconImage = iconImage; self.hint = hint
        self.preview = preview
    }

    var isFile: Bool { if case .file = preview { return true } else { return false } }
    var isClip: Bool { if case .clip = preview { return true } else { return false } }

    static let appHint = "↩ 開く　⌘↩ Finder"
    static let fileHint = "↩ 開く　⌘↩ Finder に表示"
    static let folderHint = "↩ Finder で開く　⌘↩ 場所を表示"
    static let clipHint = "↩ 貼り付け　⌘↩ コピーだけ"

    /// 親フォルダまでのパスを ~ で短くする（~/Documents/仕事）
    static func shortParent(_ path: String) -> String {
        ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    }
}

/// 一覧の 1 節（見出し＋候補）
struct ResultSection {
    var title: String
    var symbol: String
    var items: [RowItem]
    /// Engine が「見つからない」の印を付けた節。候補を薄くし、見出しに「見つかりません」を添える
    var faded = false
}

/// 中央に出る入力欄と候補の一覧（Liquid Glass・白基調）
final class SearchPanelController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    let panel: KeyPanel
    /// 中身の面（PNG の書き出しはこれを撮る）
    let content = NSView()
    private let field = NSTextField()
    private let statusIcon = NSImageView()
    private let status = NSTextField(labelWithString: "")
    /// 一覧の上に固定で出す行（チップ・知らせ・絞り込みの一覧の見出し）
    private let topStack = NSStackView()
    /// 候補の行（スクロールの中身）
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let listView = FlippedView()
    /// 作った行（results の先頭から。数が多いときは見える分から少しずつ作る）
    private var rows: [ResultRow] = []
    private var lines: [NSView] = []
    private var results: [RowItem] = []
    /// 並べる順の中身（節の見出しか、results の番号）。entries[..<built] まで作った
    private enum Entry { case header(String, String, String?); case row(Int) }
    private var entries: [Entry] = []
    private var built = 0
    private var rowAlpha: [CGFloat] = []
    private var paletteRows = false
    private var selected = 0
    /// 今の入力で、↑↓ かマウスで選び直したか。同じ入力の結果が後から届いても（件数が多いと少しずつ届く）選んだ物を動かさない
    private var userMoved = false
    private var shownQuery: String?
    private var topHeightConstraint: NSLayoutConstraint!
    /// 一覧の下の端の行（絞り込みの問い。AskBar）
    private let footer = NSView()
    private var footerHeightConstraint: NSLayoutConstraint!
    private var footerH: CGFloat = 0
    private(set) var askSplit: RecallSplit?
    /// 行を一度に作る数（数千件でも最初はこれだけ作り、スクロールで足す）
    static let rowBatch = 200
    private var iconCache: [String: NSImage] = [:]
    private var heightConstraint: NSLayoutConstraint!
    private var glassView: NSView?
    private var veilView: VeilView?
    private var glowLine: GlowLineView?
    /// 入力欄の左の稲妻（# を打ったら光らせる）
    private var boltView: NSImageView?
    /// 前に見た入力欄の # の数（増えたら光らせる）
    private var lastHashCount = 0
    private var effectView: NSVisualEffectView?
    /// 絞り込みのコマンド（#kind ss #date 7d）の一覧・チップ（FilterUI.swift）
    let filterInput = FilterInput()
    var selectedRow: Int { selected }

    /// maxRows はアプリ＋ファイルの合計
    static let width: CGFloat = 660, fieldHeight: CGFloat = 60, rowHeight: CGFloat = 48, headerHeight: CGFloat = 26,
               messageHeight: CGFloat = 52
    /// 候補の最大件数（アプリ＋ファイル。設定の「一般」）
    static var maxRows = 9

    var onQuery: ((String) -> Void)?
    /// 辞書（PhraseDictionary）に当たったアプリ・ファイル。候補の先頭の「辞書」の節に出す（AppDelegate が DictionaryLookup で渡す）
    var dictionaryCandidates: ((String) -> [Candidate])?
    /// (入力, 候補, ⌘ を押していたか)。⌘Enter は Finder に表示
    var onOpen: ((String, Candidate, Bool) -> Void)?
    var onHide: (() -> Void)?
    /// 何も打っていないときに出す節（最近の作業のまとまり。AppDelegate が渡す）
    var recentSections: (() -> [ResultSection])?
    /// 入力欄を出す直前に前面にあったアプリ（履歴から貼るときに戻す先）
    private(set) var previousApp: NSRunningApplication?

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // 影はシステムに付けてもらう。ガラスの部品と中身を丸い角で切り抜いて、影が四角く作られないようにする（下の glass と content）
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.appearance = PanelStyle.appearance
        panel.delegate = self

        // ガラス（macOS 26 以降）か、すりガラス（それより前）の上に、白い面と中身を載せる
        let veil = VeilView()
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = PanelStyle.transparency >= PanelStyle.clearGlassAbove ? .clear : .regular
            glass.cornerRadius = PanelStyle.radius
            glass.tintColor = PanelStyle.glassTint
            glass.contentView = content
            // ガラスの部品も丸い角で切り抜く（切り抜かないと四角いまま描かれ、窓の影が四角く作られて角の外に線が出る）
            glass.wantsLayer = true
            glass.layer?.cornerRadius = PanelStyle.radius
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            panel.contentView = glass
            glassView = glass
        } else {
            let bg = NSVisualEffectView()
            bg.material = PanelStyle.transparency >= 0.5 ? .underWindowBackground : .popover
            bg.blendingMode = .behindWindow
            bg.state = .active
            bg.wantsLayer = true
            bg.layer?.cornerRadius = PanelStyle.radius
            bg.layer?.masksToBounds = true
            content.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: bg.topAnchor), content.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: bg.leadingAnchor), content.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            ])
            panel.contentView = bg
            effectView = bg
        }
        veilView = veil
        content.appearance = PanelStyle.appearance
        // 中身（白い面・一覧・プレビュー）もパネルと同じ丸い角で切り抜く。切り抜かないと四角いまま描かれ、
        // 窓の影がその四角い形で作られて、角の外に四角い影が出る
        content.wantsLayer = true
        content.layer?.cornerRadius = PanelStyle.radius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true

        let glyph = NSImageView(image: symbol("bolt.fill", size: 20, weight: .semibold) ?? NSImage())
        boltView = glyph
        glyph.contentTintColor = PanelStyle.indigo
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .regular)
        field.textColor = PanelStyle.text
        // 入力欄が空のときの案内文: 「Raiden 検索」は薄いグレー、「filter: #」は # の使い方の手がかりとしてさらに薄く小さく
        field.placeholderAttributedString = Self.defaultPlaceholder
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        // 稲妻の光（# を打ったとき）に使う影。ふだんは見えない
        glyph.wantsLayer = true
        glyph.layer?.shadowColor = PanelStyle.indigo.cgColor
        glyph.layer?.shadowOpacity = 0
        glyph.layer?.shadowOffset = .zero
        statusIcon.contentTintColor = PanelStyle.faint
        status.font = .systemFont(ofSize: 12)
        status.textColor = PanelStyle.subText
        status.alignment = .right
        let sep = HairlineView()
        for st in [stack, topStack] {
            st.orientation = .vertical
            st.spacing = 0
            st.alignment = .leading
        }
        setupList(sep: sep, glyph: glyph)
    }

    /// 入力欄が空のときの案内文: 「Raiden 検索」は薄いグレー、「filter: #」は # の使い方の手がかりとしてさらに薄く小さく
    static var defaultPlaceholder: NSAttributedString {
        let ph = NSMutableAttributedString(string: "Raiden 検索", attributes: [
            .foregroundColor: PanelStyle.faint, .font: NSFont.systemFont(ofSize: 24)])
        ph.append(NSAttributedString(string: "   filter: #", attributes: [
            .foregroundColor: NSColor(white: 0.70, alpha: 1), .font: NSFont.systemFont(ofSize: 15),
            .baselineOffset: 2]))
        return ph
    }

    /// 案内文を差し替える（#alias の行き先を選んでいる間は「黒い画面 → どれに？」）。nil でいつもの案内
    func setPlaceholder(_ text: String?) {
        guard let text else { field.placeholderAttributedString = Self.defaultPlaceholder; return }
        field.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .foregroundColor: PanelStyle.faint, .font: NSFont.systemFont(ofSize: 24)])
    }

    private func setupList(sep: HairlineView, glyph: NSImageView) {
        let veil = veilView!
        // 候補の場所はスクロールできる（絞り込みで全部出すとき）。中身は上から並べる
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        listView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        listView.addSubview(stack)
        scroll.documentView = listView
        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            listView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            listView.widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: listView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: listView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: listView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: listView.bottomAnchor),
        ])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        let glow = GlowLineView()
        glowLine = glow
        sep.isHidden = true   // 区切りは光る線
        for v in [veil, glow, glyph, field, statusIcon, status, sep, topStack, scroll, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 0)
        topHeightConstraint = topStack.heightAnchor.constraint(equalToConstant: 0)
        footerHeightConstraint = footer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            veil.topAnchor.constraint(equalTo: content.topAnchor), veil.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            veil.leadingAnchor.constraint(equalTo: content.leadingAnchor), veil.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            glow.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight), glow.heightAnchor.constraint(equalToConstant: 14),
            glow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), glow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            glyph.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            glyph.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: statusIcon.leadingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            statusIcon.trailingAnchor.constraint(equalTo: status.leadingAnchor, constant: -5),
            statusIcon.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            status.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            sep.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight),
            sep.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            sep.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            sep.heightAnchor.constraint(equalToConstant: 1),
            topStack.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
            topStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topStack.widthAnchor.constraint(equalToConstant: Self.width),
            topHeightConstraint,
            scroll.topAnchor.constraint(equalTo: topStack.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: Self.width),
            heightConstraint,
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 2),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.widthAnchor.constraint(equalToConstant: Self.width),
            footerHeightConstraint,
        ])
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // ⌘Enter は入力欄の doCommandBy に来ないことがあるので、ここで拾う（日本語入力の変換中は触らない）
        // ⌥Enter（辞書に足して開く）と ⌘S（今の条件に名前を付けて保存）も同じ
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.panel.isKeyWindow else { return ev }
            if let tv = self.panel.firstResponder as? NSTextView, tv.hasMarkedText() { return ev }
            let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if ev.keyCode == 36 || ev.keyCode == 76 {
                if mods.contains(.command) { self.openSelected(reveal: true); return nil }
                if mods.contains(.option) { self.openSelected(reveal: false, addToDictionary: true); return nil }
                return ev
            }
            if ev.keyCode == 1 && mods == .command { self.filterInput.beginSave(); return nil }   // ⌘S
            // ⌘1〜⌘4: 下の端の絞り込みの問いに答える
            if mods == .command, let i = [18, 19, 20, 21].firstIndex(of: Int(ev.keyCode)), let sp = self.askSplit, sp.options.indices.contains(i) {
                self.pickAsk(i); return nil
            }
            return ev
        }
        filterInput.attach(self, field: field, content: content)
        setupPreview()
    }

    var isVisible: Bool { panel.isVisible }

    /// 透け具合を当て直す（設定を変えたとき）。ガラスの tint と白い面の濃さ、透けるほうではガラスを .clear に
    func applyTransparency() {
        let t = PanelStyle.transparency
        if #available(macOS 26.0, *), let g = glassView as? NSGlassEffectView {
            g.tintColor = PanelStyle.glassTint
            g.style = t >= PanelStyle.clearGlassAbove ? .clear : .regular
        }
        effectView?.material = t >= 0.5 ? .underWindowBackground : .popover
        veilView?.needsDisplay = true
    }

    /// クリップボードの履歴の状態で出す（専用のキー）。出ていれば履歴の状態に切り替える
    func showClipboard() {
        if !panel.isVisible || hiding { show() }
        filterInput.beginClip()
    }

    func show() {
        field.stringValue = ""
        lastHashCount = 0
        userMoved = false
        filterInput.reset()
        showRecent()
        if let f = NSWorkspace.shared.frontmostApplication, f.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = f }
        NSApp.activate(ignoringOtherApps: true)
        hiding = false
        // Spotlight のように、少し小さく薄い状態から 0.18 秒でふわっと出す。
        // 中身（ガラスの部品）の layer には触らない（基準点を変えると角の切り抜きが効かず四角い影が出た）。窓の大きさと透明度だけで動かす
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let target = panel.frame
        panel.alphaValue = 0
        if !reduce {
            let dx = (target.width * 0.03).rounded(), dy = (target.height * 0.03).rounded()
            panel.setFrame(target.insetBy(dx: dx, dy: dy), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? 0.08 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().alphaValue = 1
            if !reduce { panel.animator().setFrame(target, display: true) }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.invalidateShadow()
        })
    }

    private var hiding = false

    func hide() {
        guard panel.isVisible, !hiding else { return }
        hiding = true
        // 消すときは 0.1 秒で薄くしてから閉じる
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hiding else { return }
            self.hiding = false
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.onHide?()
        })
    }

    /// 入力欄の右の状態（準備中など）。symbol は SF Symbols の名前
    func setStatus(_ s: String, symbol name: String? = nil) {
        status.stringValue = s
        statusIcon.image = s.isEmpty ? nil : name.flatMap { symbol($0, size: 12, weight: .medium) }
    }

    /// 見本を撮るとき用（入力欄の文字を入れる）
    func setQueryText(_ s: String) {
        field.stringValue = s
        lastHashCount = s.reduce(0) { $0 + ($1 == "#" || $1 == "＃" ? 1 : 0) }
    }

    /// 入力欄をいつでも打てる状態に戻す（一覧を選んだ・チップを押した・行を押した後）。
    /// caretToEnd: カーソルを末尾に。すでに編集中なら makeFirstResponder は呼ばない（呼ぶと全選択になる）
    func focusField(caretToEnd: Bool = true) {
        if field.currentEditor() == nil { panel.makeFirstResponder(field) }
        guard caretToEnd, let ed = field.currentEditor() else { return }
        ed.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    /// 入力欄の文字（確かめ用）
    var queryText: String { field.stringValue }

    /// 入力欄の編集部品（確かめ用）
    var fieldEditor: NSText? { field.currentEditor() }

    private static var visibleFrame: NSRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// パネル全体の高さの上限（画面の高さの 65%）
    static var maxPanelHeight: CGFloat { visibleFrame.height * 0.65 }

    private func layoutPanel(top: CGFloat, list: CGFloat) {
        lastLayout = (top, list)
        topHeightConstraint.constant = top
        let maxList = max(Self.rowHeight * 3, Self.maxPanelHeight - Self.fieldHeight - 16 - top - footerH)
        let listH = min(list, maxList)
        heightConstraint.constant = listH
        footerHeightConstraint.constant = footerH
        var inner = top + listH + (footerH > 0 ? footerH + 2 : 0)
        // プレビューを出している間は、プレビューが読める高さを取る
        if wide { inner = max(inner, min(Self.previewMinHeight, Self.maxPanelHeight - Self.fieldHeight - 16)) }
        let h = Self.fieldHeight + (inner > 0 ? inner + 16 : 0)
        let vf = Self.visibleFrame
        // 上端の位置を固定して下に伸ばす（候補の数で入力欄が動かないように）
        let top = vf.maxY - vf.height * 0.22
        let w = Self.width + (wide ? FilePreviewPane.width : 0)
        let frame = NSRect(x: (vf.midX - w / 2).rounded(), y: top - h, width: w, height: h)
        if panel.isVisible && (frame.width != panel.frame.width || animatingFrame)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // 幅が変わるときは中央のまま 0.18 秒で広げる・狭める（入力欄の出方と同じ動き）
            animatingFrame = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.animatingFrame = false
                if self.panel.frame != frame { self.panel.setFrame(frame, display: true) }
                self.panel.invalidateShadow()
            })
        } else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()   // 大きさが変わったら影も作り直す（前の大きさの影が枠のように残る）
        }
    }

    /// 節ごとに並べる。中身のある節が 1 つだけなら見出しは出さない。
    /// notFound: 出している節が全部見つからない（Engine の判定）。「見つかりません」を出し、候補は薄く下に並べる。
    /// 節ごとの印（ResultSection.faded）は、その節の候補だけ薄くして見出しに「見つかりません」を添える
    /// extra: 一番上に足す行（絞り込みの一覧の見出し）。palette: 絞り込みの一覧（出ている間は検索の結果で上書きしない）
    func setResults(_ sections: [ResultSection], query: String, notFound: Bool = false,
                    extra: [(NSView, CGFloat)] = [], palette: Bool = false, split: RecallSplit? = nil) {
        guard query == filterInput.currentQuery, palette || filterInput.palette == nil else { return }
        // 下の端の絞り込みの問い（一覧・見つからない・辞書の行き先を選ぶ間は出さない）
        footer.subviews.forEach { $0.removeFromSuperview() }
        askSplit = palette || (notFound && split?.total != 0) || filterInput.isPickingAlias ? nil : split
        filterInput.asking = askSplit != nil
        if let sp = askSplit {
            let bar = AskBar(sp) { [weak self] i in self?.pickAsk(i) }
            bar.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: footer.topAnchor), bar.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
                bar.leadingAnchor.constraint(equalTo: footer.leadingAnchor), bar.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            ])
            footerH = AskBar.height
        } else {
            footerH = 0
        }
        var secs = sections.filter { !$0.items.isEmpty }
        var notFound = notFound
        if !palette && filterInput.isPickingAlias {
            // 辞書の行き先を選ぶ間はアプリを先に
            secs.sort { a, b in
                let aa = a.items.first.map { if case .app = $0.candidate { return true } else { return false } } ?? false
                let bb = b.items.first.map { if case .app = $0.candidate { return true } else { return false } } ?? false
                return aa && !bb
            }
            notFound = false
        } else if !palette, let dict = dictionaryCandidates?(query), !dict.isEmpty {
            // 辞書に当たった物を先頭に（下の節からは外す）
            let paths = Set(dict.map(\.path))
            secs = secs.map { var x = $0; x.items.removeAll { $0.candidate.map { paths.contains($0.path) } ?? false }; return x }
                .filter { !$0.items.isEmpty }
            secs.insert(ResultSection(title: "辞書", symbol: "book", items: dict.map(RowItem.init)), at: 0)
            notFound = false
        }
        // 絞り込みのコマンドが効いているときは全部出すので、節の見出しに件数を出す
        let filtered = !palette && QueryFilters.parse(query, now: filterInput.now()).isActive
        let showHeaders = secs.count > 1 || notFound || filtered || (query.isEmpty && !secs.isEmpty)
        // 同じ入力の結果の届き直しで、選び直していたなら、選んでいた物とスクロールの位置を残す
        let keep = userMoved && query == shownQuery && palette == paletteRows && results.indices.contains(selected)
        let keepKey = keep ? Self.key(results[selected]) : nil
        let keepIndex = selected
        let keepOffset = scroll.contentView.bounds.origin
        if !keep { userMoved = false }
        shownQuery = query
        results = []
        rowAlpha = []
        entries = []
        built = 0
        selected = 0
        paletteRows = palette
        rows.forEach { $0.removeFromSuperview() }
        lines.forEach { $0.removeFromSuperview() }
        topStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []
        lines = []
        var topH: CGFloat = 0
        func addTop(_ v: NSView, _ h: CGFloat) {
            v.translatesAutoresizingMaskIntoConstraints = false
            topStack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
            v.heightAnchor.constraint(equalToConstant: h).isActive = true
            topH += h
        }
        let top = palette ? extra : filterInput.topLines(sections: secs, query: query, preparing: !status.stringValue.isEmpty)
        for (v, h) in top { addTop(v, h) }
        if notFound && !query.isEmpty {
            addTop(LabelLine("見つかりません", symbol: "magnifyingglass", detail: secs.isEmpty ? nil : "近いものを薄く出しています", big: true),
                   Self.messageHeight)
        }
        var listH: CGFloat = 0
        for sec in secs {
            // 全体が見つからないときは上に大きく出しているので、節の見出しには添えない
            let fadeNote = sec.faded && !notFound ? "見つかりません" : nil
            if showHeaders || fadeNote != nil {
                let title = filtered ? "\(sec.title)  \(sec.items.count)件" : sec.title
                entries.append(.header(title, sec.symbol, fadeNote))
                listH += Self.headerHeight
            }
            for item in sec.items {
                entries.append(.row(results.count))
                results.append(item)
                rowAlpha.append(notFound || sec.faded ? 0.5 : 1)
                listH += Self.rowHeight
            }
        }
        if keep, !results.isEmpty {
            selected = results.firstIndex { Self.key($0) == keepKey } ?? min(keepIndex, results.count - 1)
        }
        buildRows(upTo: max(Self.rowBatch - 1, selected + 20))
        lastLayout = (topH, listH)
        updateWide()
        updateSelection()
        layoutPanel(top: topH, list: listH)
        if keep {
            listView.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: keepOffset)
            scroll.reflectScrolledClipView(scroll.contentView)
            scrollToSelected()
        } else {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        // 行を作り直しても入力欄は打てるままにする（カーソルの位置は動かさない）
        if panel.isVisible { focusField(caretToEnd: false) }
    }

    /// 入力欄が空なら最近の作業のまとまりを出す（最近の一覧が裏で届き直したときにも呼ぶ）
    func showRecent() {
        guard field.stringValue.isEmpty, filterInput.committed.isEmpty, filterInput.palette == nil, filterInput.currentQuery.isEmpty else { return }
        setResults(recentSections?() ?? [], query: "")
    }

    /// 絞り込みの問いの i 番目を選ぶ（打ったときと同じチップにする）
    func pickAsk(_ i: Int) {
        guard let sp = askSplit, sp.options.indices.contains(i) else { return }
        let o = sp.options[i]
        if o.replaces { filterInput.replaceQuery(o.command) } else { filterInput.acceptNext(o.command) }
    }

    /// 結果が届き直したときに同じ物か見分ける鍵
    private static func key(_ r: RowItem) -> String {
        switch r.candidate {
        case .clip(let c): return "clip:\(c.id)"
        case .some(let c): return c.path
        case nil: return "title:" + r.title
        }
    }

    /// results[index] の行まで作る（まだ作っていない見出し・行を順に足す）
    private func buildRows(upTo index: Int) {
        while built < entries.count && rows.count <= index {
            switch entries[built] {
            case .header(let title, let sym, let note):
                let v = LabelLine(title, symbol: sym, detail: note)
                v.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(v)
                v.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
                v.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true
                lines.append(v)
            case .row(let i):
                let item = results[i]
                let row = ResultRow()
                row.translatesAutoresizingMaskIntoConstraints = false
                row.title.stringValue = item.title
                row.sub.stringValue = item.sub
                row.tagLabel.stringValue = item.tag
                row.setHint(item.hint)
                row.icon.image = item.iconImage ?? item.iconPath.map(icon)
                row.alphaValue = rowAlpha[i]
                row.onClick = { [weak self] in self?.clickRow(i) }
                row.onHover = { [weak self] in self?.hoverRow(i) }
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
                rows.append(row)
            }
            built += 1
        }
    }

    /// 下の端に近づいたら次の行を作る
    @objc private func listScrolled(_ n: Notification) {
        guard built < entries.count else { return }
        let visible = scroll.contentView.bounds
        if visible.maxY > listView.frame.height - visible.height {
            buildRows(upTo: rows.count + Self.rowBatch - 1)
        }
    }

    private func hoverRow(_ i: Int) {
        guard !paletteRows, selected != i, results.indices.contains(i) else { return }
        selected = i
        userMoved = true
        updateSelection()
    }

    private func clickRow(_ i: Int) {
        if paletteRows {
            selected = i
            updateSelection()
            filterInput.acceptRow(i)
            return
        }
        selected = i
        openSelected(reveal: false)
    }

    /// 見本を撮るとき用（選択を動かす）
    func select(_ i: Int) {
        guard results.indices.contains(i) else { return }
        selected = i
        buildRows(upTo: i)
        updateSelection()
        scrollToSelected()
    }

    /// 候補の数（確かめ用）
    var resultCount: Int { results.count }
    var firstResultPath: String? { results.first?.candidate?.path }
    var builtRowCount: Int { rows.count }
    var scrollOffset: CGFloat { scroll.contentView.bounds.minY }

    private func moveSelection(_ d: Int) {
        guard !results.isEmpty else { return }
        var n = selected + d
        if n < 0 || n >= results.count {
            // 全部作ってある（ふつうの検索の数件）ときだけ端で回る。数が多いときは端で止める
            guard built >= entries.count else { return }
            n = (n + results.count) % results.count
        }
        selected = n
        userMoved = true
        buildRows(upTo: n + 20)
        updateSelection()
        scrollToSelected()
    }

    /// 選んだ行が見える位置までスクロールする
    private func scrollToSelected() {
        guard rows.indices.contains(selected) else { return }
        listView.layoutSubtreeIfNeeded()
        let row = rows[selected]
        var r = row.convert(row.bounds, to: listView)
        // 先頭の行なら節の見出しまで見せる
        if selected == 0 { r.origin.y = 0; r.size.height += Self.headerHeight }
        listView.scrollToVisible(r)
    }

    private func icon(_ path: String) -> NSImage {
        if let i = iconCache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 64, height: 64)
        // ファイルは数が多いので、溜まりすぎたら捨てる
        if iconCache.count > 2000 { iconCache.removeAll() }
        iconCache[path] = i
        return i
    }

    private func updateSelection() {
        for (i, r) in rows.enumerated() where r.selected != (i == selected) { r.selected = i == selected }
        updateWide()   // アプリの行に移ったら閉じ、ファイルの行に移ったら広げる（setWide が並べ直す）
        updatePreview()
    }

    // MARK: プレビュー

    /// 右のプレビュー（ファイルの行があるときだけパネルを広げて出す）
    let preview = FilePreviewPane()
    private let previewLine = HairlineView()
    /// プレビューを出すか（設定の「一般 → ファイルのプレビューを出す」）
    static var previewEnabled = true
    /// 今パネルを広げているか（狭めるのは少し待つ。打っている途中でファイルの行が出たり消えたりしてもガタつかないように）
    private(set) var wide = false
    private var shrinkPending: DispatchWorkItem?
    private var lastLayout: (top: CGFloat, list: CGFloat) = (0, 0)
    private var animatingFrame = false
    static let previewMinHeight: CGFloat = 360

    /// 画面がプレビューを並べられる幅か
    static var screenFitsPreview: Bool { visibleFrame.width >= width + FilePreviewPane.width + 80 }

    /// 今の候補で広げたいか（ファイルの行がある・絞り込みの一覧ではない・設定がオン・画面が広い）
    private var wantsWide: Bool {
        // 選んでいる行がファイル・フォルダの時だけ（アプリの行ではプレビューを出さない）
        // 何も打っていないときの最近のまとまりは、↑↓ で選び直すまで出さない（開くたびに窓が広がらないように）
        Self.previewEnabled && !paletteRows && Self.screenFitsPreview && results.indices.contains(selected) && (results[selected].isFile || results[selected].isClip)
            && !(shownQuery?.isEmpty == true && !userMoved)
    }

    private func updatePreview() {
        guard wide, results.indices.contains(selected) else { preview.show(nil, title: "", icon: nil); return }
        let item = results[selected]
        let img = rows.indices.contains(selected) ? rows[selected].icon.image : nil
        preview.show(item.preview, title: item.title, icon: img)
    }

    private func setupPreview() {
        for v in [preview, previewLine] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.alphaValue = 0
            content.addSubview(v)
        }
        // 下端は弱くつなぐ（プレビューを出していない入力欄だけの時に、中身の最低の高さがパネルを押し広げないように）
        let pb = preview.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        pb.priority = .defaultLow
        let lb = previewLine.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        lb.priority = .defaultLow
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.width),
            preview.widthAnchor.constraint(equalToConstant: FilePreviewPane.width),
            preview.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight + 1),
            pb,
            previewLine.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.width),
            previewLine.widthAnchor.constraint(equalToConstant: 1),
            previewLine.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight + 14),
            lb,
        ])
    }

    /// 広げる・狭める。広げるのはすぐ、狭めるのは 0.25 秒待ってまだ要らなければ
    private func updateWide() {
        let want = wantsWide
        if want {
            shrinkPending?.cancel(); shrinkPending = nil
            if !wide { setWide(true) }
        } else if wide {
            // 開いていない（見本・確かめ）・候補が空・設定を切ったときはすぐ
            if !panel.isVisible || results.isEmpty || !Self.previewEnabled { setWide(false); return }
            guard shrinkPending == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.shrinkPending = nil
                if !self.wantsWide && self.wide { self.setWide(false) }
            }
            shrinkPending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        }
    }

    private func setWide(_ on: Bool) {
        wide = on
        let animate = panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                preview.animator().alphaValue = on ? 1 : 0
                previewLine.animator().alphaValue = on ? 1 : 0
            }
        } else {
            preview.alphaValue = on ? 1 : 0
            previewLine.alphaValue = on ? 1 : 0
        }
        layoutPanel(top: lastLayout.top, list: lastLayout.list)
        updatePreview()
    }

    /// addToDictionary: ⌥Enter。今の言葉 → 選んだ物を辞書に足してから開く。#alias の行き先を選んでいる間は開かずに辞書に足す
    private func openSelected(reveal: Bool, addToDictionary: Bool = false) {
        guard results.indices.contains(selected), let c = results[selected].candidate else { return }
        if filterInput.isPickingAlias { filterInput.pickAlias(c); return }
        if addToDictionary { filterInput.addToDictionary(c) }
        let q = QueryFilters.parse(filterInput.currentQuery).text   // 覚えるのはコマンドを抜いた言葉
        hide()
        onOpen?(q, c, reveal)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        let n = field.stringValue.reduce(0) { $0 + ($1 == "#" || $1 == "＃" ? 1 : 0) }
        if n > lastHashCount { flashBolt() }
        filterInput.textDidChange()
        lastHashCount = field.stringValue.reduce(0) { $0 + ($1 == "#" || $1 == "＃" ? 1 : 0) }
    }

    /// 稲妻をピカッと光らせる（0.9 秒）。稲妻のまわりに藍の光が広がって消え、印が大きくなって戻る。
    /// 「視差効果を減らす」がオンなら大きさは変えず光だけ
    func flashBolt() {
        guard let v = boltView, let l = v.layer else { return }
        let dur = 0.9
        let glow = CAAnimationGroup()
        let color = CABasicAnimation(keyPath: "shadowColor")
        color.fromValue = PanelStyle.indigo.cgColor; color.toValue = PanelStyle.indigo.cgColor
        let radius = CAKeyframeAnimation(keyPath: "shadowRadius")
        radius.values = [2, 20, 16, 4]; radius.keyTimes = [0, 0.15, 0.45, 1]
        let opacity = CAKeyframeAnimation(keyPath: "shadowOpacity")
        opacity.values = [0, 0.9, 0.9, 0]; opacity.keyTimes = [0, 0.12, 0.45, 1]
        var parts: [CAAnimation] = [color, radius, opacity]
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // 層の基準点は左下なので、真ん中を中心に大きくする
            let c = CGPoint(x: l.bounds.midX, y: l.bounds.midY)
            func scale(_ k: CGFloat) -> NSValue {
                var t = CATransform3DMakeTranslation(c.x, c.y, 0)
                t = CATransform3DScale(t, k, k, 1)
                return NSValue(caTransform3D: CATransform3DTranslate(t, -c.x, -c.y, 0))
            }
            let pop = CAKeyframeAnimation(keyPath: "transform")
            pop.values = [scale(1), scale(1.6), scale(1.45), scale(0.92), scale(1)]
            pop.keyTimes = [0, 0.14, 0.32, 0.65, 1]
            parts.append(pop)
        }
        glow.animations = parts
        glow.duration = dur
        l.removeAnimation(forKey: "flash")
        l.add(glow, forKey: "flash")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if filterInput.handle(sel) { return true }
        switch sel {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // 日本語入力の変換中の Enter は確定に使う（ここには来ない）
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            openSelected(reveal: mods.contains(.command), addToDictionary: mods.contains(.option))
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            openSelected(reveal: false, addToDictionary: true)   // ⌥Enter
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    /// 入力欄の編集部品。カーソルと変換中の下線は藍
    private lazy var bandEditor: NSTextView = {
        let tv = BandFieldEditor()
        tv.isFieldEditor = true
        tv.insertionPointColor = PanelStyle.caret
        tv.selectedTextAttributes = [.backgroundColor: NSColor(srgbRed: 0.231, green: 0.204, blue: 0.839, alpha: 0.18)]
        tv.markedTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: PanelStyle.caret]
        return tv
    }()

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? NSTextField) === field ? bandEditor : nil
    }
}
