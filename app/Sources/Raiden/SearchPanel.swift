import AppKit
import QuartzCore
import RaidenCore

/// 入力欄を持てる枠なしパネル
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// パネルの色。中身は Kodou-ui の値（Kodou.swift の K）。古い名前は呼ぶ側を直すまでの別名
enum PanelStyle {
    static var appearance: NSAppearance? { K.appearance }
    static var text: NSColor { K.fg }
    static var subText: NSColor { K.dim }
    static var faint: NSColor { K.faint }
    /// Raiden の色（アイコンの稲妻の藍）＝ Kodou-ui のアクセント
    static var indigo: NSColor { K.accent }
    static var caret: NSColor { K.accent }
    static var separator: NSColor { K.ruleSoft }
}

/// 入力欄の下の線。入力欄はいつもフォーカスがあるので、Kodou-ui のテキスト入力のフォーカス（下に 2px のアクセントの線）を引く
final class FocusLineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        K.accent.setFill()
        bounds.fill()
    }
}

/// 入力欄の編集部品。変換中の文字の下線を藍にする（日本語入力が付ける線の太さはそのまま、色だけ変える）
final class BandFieldEditor: NSTextView {
    /// 文字か変換中の文字が変わったとき（案内文を出すか決め直す）
    var onEdit: (() -> Void)?
    override func unmarkText() { super.unmarkText(); onEdit?() }
    override func didChangeText() { super.didChangeText(); onEdit?() }
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
        onEdit?()
    }
}

/// 検索の入力欄。字は欄の高さの真ん中に描く（JetBrains Mono に日本語の字体が混ざると、
/// NSTextField の既定では日本語の字の上が欄からはみ出して切れる。欄を高くし、字の行を真ん中に置く）
final class BandField: NSTextField {
    override class var cellClass: AnyClass? { get { BandFieldCell.self } set {} }
    /// コードから文字を書き換えたとき（「#」の一覧で選んだ・取り消した）にも案内文を決め直す
    var onSet: (() -> Void)?
    override var stringValue: String { didSet { onSet?() } }
}

final class BandFieldCell: NSTextFieldCell {
    /// 日本語と英字を混ぜた 1 行の実際の高さ（字体を混ぜた分も含む）
    private func lineHeight() -> CGFloat {
        let f = font ?? K.mono(20)
        return ceil(NSAttributedString(string: "Rg検索あ", attributes: [.font: f]).size().height)
    }
    private func centered(_ r: NSRect) -> NSRect {
        let h = min(r.height, lineHeight())
        return NSRect(x: r.minX, y: r.minY + ((r.height - h) / 2).rounded(), width: r.width, height: h)
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { centered(super.drawingRect(forBounds: rect)) }
    override func titleRect(forBounds rect: NSRect) -> NSRect { centered(super.titleRect(forBounds: rect)) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

/// 1 px の区切り線
final class HairlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        PanelStyle.separator.setFill()
        bounds.fill()
    }
}

/// 候補 1 行（アイコン・名前・場所）。選択中は反転表示（Kodou-ui のリスト）。左端の縦線や帯は使わない。
/// 操作の手がかり（↩ 開く・⌘↩ Finder）は行には出さず、パネルの下のキーの帯に出す（SearchPanelController.keyBand）
final class ResultRow: NSView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let sub = NSTextField(labelWithString: "")
    /// 操作の手がかり（キーの帯に出す元の文字。行には出さない）
    private(set) var hintText = ""
    /// 見出しの右に小さく添える文字（「#」の一覧のコマンド名 #date #k）。アクセント・等幅
    let tagLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    var selected = false {
        didSet { needsDisplay = true; applyColors() }
    }

    func setHint(_ s: String) { hintText = s }

    /// 反転しているときは中の文字も反転の色にそろえる
    private func applyColors() {
        title.textColor = selected ? K.selFg : K.fg
        sub.textColor = selected ? K.selDim : K.dim
        tagLabel.textColor = selected ? K.selFg : K.accent
        if card { icon.contentTintColor = selected ? K.selFg : K.accent }
        else if icon.image?.isTemplate == true { icon.contentTintColor = selected ? K.selFg : K.dim }
    }

    /// カードの形（2 列の「入口」）: 1px の罫線の四角、アイコンは地のまま、右端にコマンド
    private(set) var card = false

    convenience init(card: Bool) {
        self.init(frame: .zero)
        guard card else { return }
        self.card = true
        NSLayoutConstraint.deactivate(constraints)
        for v in [icon, title, sub, tagLabel] as [NSView] { v.removeFromSuperview() }
        icon.contentTintColor = K.accent
        icon.imageScaling = .scaleNone
        title.font = K.mono(13, bold: true)
        sub.font = K.read(11.5)
        sub.lineBreakMode = .byTruncatingTail
        for v in [icon, title, sub, tagLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        tagLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        tagLabel.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: tagLabel.leadingAnchor, constant: -8),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: tagLabel.leadingAnchor, constant: -8),
            tagLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tagLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyColors()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = K.mono(14)
        title.lineBreakMode = .byTruncatingTail
        sub.font = K.mono(11.5)
        sub.lineBreakMode = .byTruncatingMiddle
        tagLabel.font = K.mono(11.5, bold: true)
        tagLabel.lineBreakMode = .byTruncatingTail
        for v in [icon, title, sub, tagLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        tagLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            tagLabel.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            tagLabel.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            tagLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if card {
            if selected { K.selBg.setFill(); bounds.fill(); return }
            K.rule.setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
            return
        }
        guard selected else { return }
        // 枠の内側いっぱいに反転（角は丸めない）
        K.selBg.setFill()
        bounds.insetBy(dx: KFrameView.inset + 1, dy: 0).fill()
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

/// アイコンと文字の 1 行（節の見出し・「見つかりません」）。選べない。
/// 節の見出しは区切り線の形（── アプリ ───────── 3 件）: 名前のあとを細い罫線でつなぎ、件数を右端に置く
final class LabelLine: NSView {
    private var ruleFrom: NSTextField?
    private var ruleTo: NSView?
    private let big: Bool

    /// count: 右の端にそろえて出す件数（「12 件」。時期の棚など）。plain: 大きい一文を太字にしない
    init(_ text: String, symbol name: String, detail: String? = nil, big: Bool = false, count: String? = nil, plain: Bool = false) {
        self.big = big
        super.init(frame: .zero)
        let glyph = NSImageView(image: symbol(name, size: big ? 14 : 12) ?? NSImage())
        glyph.contentTintColor = big ? K.dim : K.accent
        let label = NSTextField(labelWithString: text)
        label.font = big ? K.read(14, bold: !plain) : K.mono(11.5, bold: true)
        label.textColor = big ? K.fg : K.dim
        var views: [NSView] = [glyph, label]
        let d = NSTextField(labelWithString: detail ?? "")
        d.font = K.read(11.5)
        d.textColor = K.faint
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
        var c: NSTextField?
        if let count {
            let l = NSTextField(labelWithString: count)
            l.font = K.mono(11.5)
            l.textColor = K.faint
            l.translatesAutoresizingMaskIntoConstraints = false
            addSubview(l)
            NSLayoutConstraint.activate([
                l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
                l.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            ])
            c = l
        }
        guard !big else { return }
        ruleFrom = detail != nil ? d : label
        ruleTo = c
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard !big, let from = ruleFrom else { return }
        let x0 = from.frame.maxX + 8
        let x1 = (ruleTo?.frame.minX ?? bounds.maxX - 20 + 8) - 8
        guard x1 > x0 else { return }
        K.ruleSoft.setFill()
        NSRect(x: x0, y: from.frame.midY.rounded(), width: x1 - x0, height: 1).fill()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
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
    /// 2 列のカードで出す（「#」の一覧のコマンド。HTML の画面案の「入口」）
    var card = false
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
    static let fileHint = "↩ 開く　⌘↩ Finder に表示　⌘→ 基準に"
    static let folderHint = "↩ Finder で開く　⌘↩ 場所を表示　⌘→ 基準に"
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
    private let field = BandField()
    private let placeholderLabel = NSTextField(labelWithString: "")
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
    /// 2 列のカードで並べている（↑↓ で 2 つ、←→ で 1 つ動く）
    private var grid = false
    /// カードの始まりの添字（その前は 1 列の行。カードは 1 かたまりで最後まで続く）
    private var cardStart: Int?
    static let cardHeight: CGFloat = 54, cardGap: CGFloat = 6
    private var lines: [NSView] = []
    private var results: [RowItem] = []
    /// 並べる順の中身（節の見出しか、results の番号）。entries[..<built] まで作った
    private enum Entry { case header(String, String, String?, String?); case row(Int); case pair(Int, Int?) }
    private var entries: [Entry] = []
    private var built = 0
    private var rowAlpha: [CGFloat] = []
    private var paletteRows = false
    private var selected = 0
    /// 今の入力で、↑↓ かマウスで選び直したか。同じ入力の結果が後から届いても（件数が多いと少しずつ届く）選んだ物を動かさない
    private var userMoved = false
    private var shownQuery: String?
    private var topHeightConstraint: NSLayoutConstraint!
    /// 一覧の上の行（絞り込みの問い。AskBar）
    private let footer = NSView()
    private var footerHeightConstraint: NSLayoutConstraint!
    private var footerH: CGFloat = 0
    private(set) var askSplit: RecallSplit?
    /// 行を一度に作る数（数千件でも最初はこれだけ作り、スクロールで足す）
    static let rowBatch = 200
    private var iconCache: [String: NSImage] = [:]
    /// 古い順（先頭が一番前に使った物）。上限を超えたら先頭から捨てる
    private var iconOrder: [String] = []
    static let iconCacheLimit = 300
    private var heightConstraint: NSLayoutConstraint!
    /// 地と罫線の枠（左上に名前、右上に状態）
    private let frameView = KFrameView()
    private let frameTitle = KFrameView.title(" raiden ")
    /// 右上の状態（準備中など）。地の色で枠の線を切る
    private let statusBox: KFill = { let v = KFill(K.panel); v.isHidden = true; return v }()
    /// 入力欄の下のフォーカスの線
    private let focusLine = FocusLineView()
    /// 下のキーの帯（選んでいる行で効くキー・件数・入力から描き終わるまでの時間）
    private let keyBand = NSTextField(labelWithString: "")
    private let bandInfo = NSTextField(labelWithString: "")
    private let bandRule = KFill(K.ruleSoft)
    static let bandHeight: CGFloat = 28
    /// 最後に打った時刻（入力から描き終わるまでを測る）
    private var typedAt: CFTimeInterval?
    private var lastDrawMs: Double?
    /// 入力欄の左の稲妻（# を打ったら光らせる）
    private var boltView: NSImageView?
    /// 前に見た入力欄の # の数（増えたら光らせる）
    private var lastHashCount = 0
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
        panel.backgroundColor = K.panel
        panel.isOpaque = true
        // 影はシステムに付けてもらう（角は丸めないので四角い影のまま）
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.appearance = PanelStyle.appearance
        panel.delegate = self

        // 地と罫線の枠の上に中身を載せる（Kodou-ui のパネル。角は丸めず、透かさない）
        panel.contentView = content
        content.appearance = PanelStyle.appearance

        let glyph = NSImageView(image: symbol("bolt", size: 18) ?? NSImage())
        boltView = glyph
        glyph.contentTintColor = K.accent
        glyph.wantsLayer = true
        glyph.imageScaling = .scaleNone
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = K.mono(20)
        field.textColor = K.fg
        // 入力欄が空のときの案内文: 「Raiden 検索」は薄く、「filter: #」は # の使い方の手がかりとして小さく
        // 案内文は欄の外のラベルで出す（欄の案内文は編集中に入力の部品が別に描き、字の上が切れたため）
        placeholderLabel.attributedStringValue = Self.defaultPlaceholder
        placeholderLabel.lineBreakMode = .byTruncatingTail
        field.onSet = { [weak self] in self?.updatePlaceholder() }
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        statusIcon.contentTintColor = K.faint
        status.font = K.mono(11.5)
        status.textColor = K.dim
        status.alignment = .right
        keyBand.lineBreakMode = .byTruncatingTail
        bandInfo.font = K.mono(11.5)
        bandInfo.textColor = K.faint
        bandInfo.alignment = .right
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
            .foregroundColor: K.faint, .font: K.mono(20)])
        ph.append(NSAttributedString(string: "   filter: #", attributes: [
            .foregroundColor: K.faint, .font: K.mono(12), .baselineOffset: 3]))
        return ph
    }

    /// 案内文を差し替える（#alias の行き先を選んでいる間は「黒い画面 → どれに？」）。nil でいつもの案内
    func setPlaceholder(_ text: String?) {
        placeholderLabel.attributedStringValue = text.map {
            NSAttributedString(string: $0, attributes: [.foregroundColor: K.faint, .font: K.mono(20)])
        } ?? Self.defaultPlaceholder
        updatePlaceholder()
    }

    /// 案内文は、欄が空で変換中の字も無いときだけ出す
    private func updatePlaceholder() {
        let marked = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        placeholderLabel.isHidden = !field.stringValue.isEmpty || marked
    }

    private func setupList(sep: HairlineView, glyph: NSImageView) {
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

        sep.isHidden = true   // 区切りはフォーカスの線
        let inset = KFrameView.inset
        statusBox.subviews.forEach { $0.removeFromSuperview() }
        for v in [statusIcon, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            statusBox.addSubview(v)
        }
        for v in [frameView, focusLine, glyph, placeholderLabel, field, frameTitle, statusBox, sep, topStack, scroll, footer, bandRule, keyBand, bandInfo] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 0)
        topHeightConstraint = topStack.heightAnchor.constraint(equalToConstant: 0)
        footerHeightConstraint = footer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            frameView.topAnchor.constraint(equalTo: content.topAnchor), frameView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            frameView.leadingAnchor.constraint(equalTo: content.leadingAnchor), frameView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            frameTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            frameTitle.centerYAnchor.constraint(equalTo: content.topAnchor, constant: inset + 0.5),
            statusBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusBox.centerYAnchor.constraint(equalTo: content.topAnchor, constant: inset + 0.5),
            statusBox.heightAnchor.constraint(equalToConstant: 16),
            statusIcon.leadingAnchor.constraint(equalTo: statusBox.leadingAnchor, constant: 4),
            statusIcon.centerYAnchor.constraint(equalTo: statusBox.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 4),
            status.trailingAnchor.constraint(equalTo: statusBox.trailingAnchor, constant: -4),
            status.centerYAnchor.constraint(equalTo: statusBox.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            glyph.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            // 稲妻と入力欄は、枠の上の線とフォーカスの線のあいだの真ん中（7〜58pt の中央 ≈ 33）にそろえる
            glyph.centerYAnchor.constraint(equalTo: content.topAnchor, constant: (KFrameView.inset + 1 + Self.fieldHeight - 2) / 2 + 3),
            field.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            // 欄は高めに取り、字は BandFieldCell が欄の真ん中に描く
            field.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 40),
            // 欄の字の描き始め（左 2pt）と同じ所から
            placeholderLabel.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: field.trailingAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            focusLine.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight - 2),
            focusLine.heightAnchor.constraint(equalToConstant: 2),
            focusLine.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset + 1),
            focusLine.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -(inset + 1)),
            sep.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight),
            sep.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            sep.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            sep.heightAnchor.constraint(equalToConstant: 1),
            topStack.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
            topStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topStack.widthAnchor.constraint(equalToConstant: Self.width),
            topHeightConstraint,
            // 絞り込みの問い（footer の名前のまま。今はチップの下・一覧の上）
            footer.topAnchor.constraint(equalTo: topStack.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: footer.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: Self.width),
            heightConstraint,
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.widthAnchor.constraint(equalToConstant: Self.width),
            footerHeightConstraint,
            // 下のキーの帯（枠の内側の一番下。プレビューを出しているときも全体の幅）
            bandRule.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -(inset + 1) - Self.bandHeight),
            bandRule.heightAnchor.constraint(equalToConstant: 1),
            bandRule.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset + 1),
            bandRule.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -(inset + 1)),
            keyBand.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            keyBand.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -(inset + 1) - Self.bandHeight / 2),
            keyBand.trailingAnchor.constraint(lessThanOrEqualTo: bandInfo.leadingAnchor, constant: -12),
            bandInfo.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            bandInfo.centerYAnchor.constraint(equalTo: keyBand.centerYAnchor),
        ])
        keyBand.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bandInfo.setContentCompressionResistancePriority(.required, for: .horizontal)
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
            // ⌘→: 選んでいるファイル・フォルダを基準に #with / #near を選ぶ（入力欄のカーソル移動より先に取る）
            if ev.keyCode == 124, mods.subtracting([.function, .numericPad]) == .command, self.askAboutSelected() { return nil }
            // ⌘1〜⌘4: 一覧の上の絞り込みの問いに答える
            if mods == .command, let i = [18, 19, 20, 21].firstIndex(of: Int(ev.keyCode)), let sp = self.askSplit, sp.options.indices.contains(i) {
                self.pickAsk(i); return nil
            }
            return ev
        }
        filterInput.attach(self, field: field, content: content)
        setupPreview()
    }

    var isVisible: Bool { panel.isVisible }

    /// 外観を当て直す（設定を変えたとき）。色は外観に合わせて変わる NSColor なので、外観を差し替えて描き直すだけ
    func applyTheme() {
        panel.appearance = K.appearance
        content.appearance = K.appearance
        panel.backgroundColor = K.panel
        content.needsDisplay = true
        func redraw(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(redraw) }
        redraw(content)
    }

    /// クリップボードの履歴の状態で出す（専用のキー）。出ていれば履歴の状態に切り替える
    func showClipboard() {
        if !panel.isVisible || hiding { show() }
        filterInput.beginClip()
    }

    func show() {
        field.stringValue = ""
        updatePlaceholder()
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
            let dx = (target.width * 0.015).rounded(), dy = (target.height * 0.015).rounded()
            panel.setFrame(target.insetBy(dx: dx, dy: dy), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? K.tFast : K.tBase
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
            ctx.duration = K.tFast
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hiding else { return }
            self.hiding = false
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.onHide?()
            // 閉じたあと一覧の部品を手放す（次に開く時は show() で作り直す）。onHide の後片付けが済んでから
            DispatchQueue.main.async { [weak self] in self?.releaseContent() }
        })
    }

    /// 閉じている間は行・見出し・問いの部品を持たない。空いたページは malloc から OS へ返す
    private func releaseContent() {
        guard !panel.isVisible else { return }
        rows.forEach { $0.removeFromSuperview() }
        lines.forEach { $0.removeFromSuperview() }
        topStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        footer.subviews.forEach { $0.removeFromSuperview() }
        rows = []
        lines = []
        results = []
        rowAlpha = []
        entries = []
        built = 0
        selected = 0
        askSplit = nil
        malloc_zone_pressure_relief(nil, 0)
    }

    /// 入力欄の右の状態（準備中など）。symbol は SF Symbols の名前
    func setStatus(_ s: String, symbol name: String? = nil) {
        status.stringValue = s
        statusIcon.image = s.isEmpty ? nil : name.flatMap { symbol($0, size: 12) }
        statusBox.isHidden = s.isEmpty
    }

    /// 見本を撮るとき用（入力欄の文字を入れる）
    func setQueryText(_ s: String) {
        field.stringValue = s
        updatePlaceholder()
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

    /// 一覧の下から窓の下端まで（すき間・キーの帯・枠）
    static var chromeBottom: CGFloat { 6 + bandHeight + KFrameView.inset + 1 }

    private func layoutPanel(top: CGFloat, list: CGFloat) {
        lastLayout = (top, list)
        topHeightConstraint.constant = top
        let maxList = max(Self.rowHeight * 3, Self.maxPanelHeight - Self.fieldHeight - Self.chromeBottom - top - footerH)
        let listH = min(list, maxList)
        heightConstraint.constant = listH
        footerHeightConstraint.constant = footerH
        var inner = top + listH + footerH
        // プレビューを出している間は、プレビューが読める高さを取る
        if wide { inner = max(inner, min(Self.previewMinHeight, Self.maxPanelHeight - Self.fieldHeight - Self.chromeBottom)) }
        let h = Self.fieldHeight + inner + Self.chromeBottom
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
                ctx.duration = K.tBase
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
        // 一覧の上の絞り込みの問い（一覧・見つからない・辞書の行き先を選ぶ間は出さない）
        installAsk(palette || (notFound && split?.total != 0) || filterInput.isPickingAlias ? nil : split)
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
        cardStart = nil
        for sec in secs {
            // 全体が見つからないときは上に大きく出しているので、節の見出しには添えない
            let fadeNote = sec.faded && !notFound ? "見つかりません" : nil
            if showHeaders || fadeNote != nil {
                entries.append(.header(sec.title, sec.symbol, fadeNote, filtered ? "\(sec.items.count) 件" : nil))
                listH += Self.headerHeight
            }
            // カードは 2 つずつ 1 段に、それ以外（保存した条件・よく使う組み合わせ）は 1 行ずつ
            var k = 0
            let items = sec.items
            while k < items.count {
                let i = results.count
                if items[k].card {
                    if cardStart == nil { cardStart = i }
                    let two = k + 1 < items.count && items[k + 1].card
                    for item in items[k..<(k + (two ? 2 : 1))] { results.append(item); rowAlpha.append(1) }
                    entries.append(.pair(i, two ? i + 1 : nil))
                    listH += Self.cardHeight + Self.cardGap
                    k += two ? 2 : 1
                } else {
                    entries.append(.row(i))
                    results.append(items[k])
                    rowAlpha.append(notFound || sec.faded ? 0.5 : 1)
                    listH += Self.rowHeight
                    k += 1
                }
            }
        }
        if keep, !results.isEmpty {
            selected = results.firstIndex { Self.key($0) == keepKey } ?? min(keepIndex, results.count - 1)
        }
        grid = cardStart != nil
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
        measureDraw()
    }

    /// 下のキーの帯: 選んでいる行で効くキー（左）と、件数・最後に打ってから描き終わるまでの時間（右）
    private func updateKeyBand() {
        let hint: String
        if results.indices.contains(selected) { hint = results[selected].hint + "　Esc 閉じる" }
        else { hint = "# 絞り込み　Esc 閉じる" }
        keyBand.attributedStringValue = K.keys(hint)
        var info: [String] = []
        if !results.isEmpty { info.append("\(results.count) 件") }
        if let ms = lastDrawMs { info.append(String(format: "%.0fms", ms)) }
        bandInfo.stringValue = info.joined(separator: " · ")
    }

    /// 最後に打ってから、次の画面が描き終わるまで（Kodou-ui の目安は 16ms）
    private func measureDraw() {
        guard let t0 = typedAt else { updateKeyBand(); return }
        typedAt = nil
        content.displayIfNeeded()
        lastDrawMs = (CACurrentMediaTime() - t0) * 1000
        updateKeyBand()
    }

    /// 入力欄が空なら最近の作業のまとまりを出す（最近の一覧が裏で届き直したときにも呼ぶ）
    func showRecent() {
        guard field.stringValue.isEmpty, filterInput.committed.isEmpty, filterInput.palette == nil, filterInput.currentQuery.isEmpty else { return }
        setResults(recentSections?() ?? [], query: "")
    }

    /// 一覧の上に問いを出す（nil なら消す）。高さは footerH に入れ、並べ直しは呼ぶ側
    private func installAsk(_ sp: RecallSplit?) {
        footer.subviews.forEach { $0.removeFromSuperview() }
        askSplit = sp
        filterInput.asking = sp != nil
        guard let sp else { footerH = 0; return }
        let bar = AskBar(sp, width: Self.width) { [weak self] i in self?.pickAsk(i) }
        bar.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: footer.topAnchor), bar.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: footer.leadingAnchor), bar.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
        ])
        footerH = bar.preferredHeight
    }

    /// 選んでいるファイル・フォルダを基準にする問い（⌘→）。「一緒に使ったもの」（#with）か「同じプロジェクト」（#near）を
    /// ⌘1・⌘2 か押して選ぶと、入力を書き換えてそのチップだけにする（打っていた言葉は外す。名前で絞られないように）
    @discardableResult
    func askAboutSelected() -> Bool {
        guard !paletteRows, results.indices.contains(selected), case .file(let r)? = results[selected].candidate else { return false }
        let short = (r.file.path as NSString).abbreviatingWithTildeInPath
        let v = short.contains(where: \.isWhitespace) ? "\"\(short)\"" : short
        let name = (r.file.path as NSString).lastPathComponent
        let sp = RecallSplit(title: "「\(name)」を基準に探す", total: 0, options: [
            .init(label: "一緒に使ったもの", symbol: "link", command: "#with " + v, count: -1, replaces: true),
            .init(label: "同じプロジェクト", symbol: "point.3.connected.trianglepath.dotted", command: "#near " + v, count: -1, replaces: true),
        ])
        installAsk(sp)
        layoutPanel(top: lastLayout.top, list: lastLayout.list)
        return true
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
            case .header(let title, let sym, let note, let count):
                let v = LabelLine(title, symbol: sym, detail: note, count: count)
                v.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(v)
                v.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
                v.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true
                lines.append(v)
            case .row(let i):
                let row = makeRow(i)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
                rows.append(row)
            case .pair(let i, let j):
                // 2 列のカード 1 段。左右の余白は 16、間は cardGap
                let line = NSView()
                line.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
                line.heightAnchor.constraint(equalToConstant: Self.cardHeight + Self.cardGap).isActive = true
                let w = (Self.width - 32 - Self.cardGap) / 2
                for (n, k) in [i, j].compactMap({ $0 }).enumerated() {
                    let c = makeRow(k)
                    line.addSubview(c)
                    NSLayoutConstraint.activate([
                        c.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: 16 + CGFloat(n) * (w + Self.cardGap)),
                        c.topAnchor.constraint(equalTo: line.topAnchor),
                        c.widthAnchor.constraint(equalToConstant: w), c.heightAnchor.constraint(equalToConstant: Self.cardHeight),
                    ])
                    rows.append(c)
                }
                lines.append(line)
            }
            built += 1
        }
    }

    private func makeRow(_ i: Int) -> ResultRow {
        let item = results[i]
        let row = ResultRow(card: item.card)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.title.stringValue = item.title
        row.sub.stringValue = item.sub
        row.tagLabel.stringValue = item.tag
        row.setHint(item.hint)
        row.icon.image = item.iconImage ?? item.iconPath.map(icon)
        // ドット絵（テンプレート画像）は拡大縮小せず、マスのまま描く
        if row.icon.image?.isTemplate == true {
            row.icon.imageScaling = .scaleNone
            if !item.card { row.icon.contentTintColor = K.dim }
        }
        row.alphaValue = rowAlpha[i]
        row.onClick = { [weak self] in self?.clickRow(i) }
        row.onHover = { [weak self] in self?.hoverRow(i) }
        return row
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

    private var onCard: Bool { cardStart.map { selected >= $0 } ?? false }

    /// ↑↓ で動く数。カードの間は 1 段（2 つ）、1 列の行からカードへ・カードから 1 列の行へは隣へ
    private func verticalStep(_ d: Int) -> Int {
        guard let cs = cardStart, selected >= cs else { return d }
        let n = selected + 2 * d
        if d < 0 && n < cs { return cs > 0 ? (cs - 1) - selected : d }   // 一番上の段から上: 1 列の最後の行へ
        if d > 0 && n >= results.count {
            // 最後の段の 1 つ上で、右の列には下が無い: 最後のカードへ。最後の段からは一番上へ回る
            return (selected - cs) / 2 < (results.count - 1 - cs) / 2 ? (results.count - 1) - selected : -selected
        }
        return 2 * d
    }

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
        if let i = iconCache[path] {
            if let k = iconOrder.lastIndex(of: path) { iconOrder.remove(at: k) }
            iconOrder.append(path)
            return i
        }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 64, height: 64)
        // 1 つのアイコンが解像度違いの絵を十数枚抱えるので、最近使った物だけ残す
        if iconOrder.count >= Self.iconCacheLimit {
            iconCache[iconOrder.removeFirst()] = nil
        }
        iconCache[path] = i
        iconOrder.append(path)
        return i
    }

    private func updateSelection() {
        for (i, r) in rows.enumerated() where r.selected != (i == selected) { r.selected = i == selected }
        updateKeyBand()
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
        let pb = preview.bottomAnchor.constraint(equalTo: bandRule.topAnchor, constant: -6)
        pb.priority = .defaultLow
        let lb = previewLine.bottomAnchor.constraint(equalTo: bandRule.topAnchor)
        lb.priority = .defaultLow
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.width),
            preview.widthAnchor.constraint(equalToConstant: FilePreviewPane.width),
            preview.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight + 1),
            pb,
            previewLine.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.width),
            previewLine.widthAnchor.constraint(equalToConstant: 1),
            previewLine.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight),
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
                ctx.duration = K.tBase
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
        typedAt = CACurrentMediaTime()
        updatePlaceholder()
        filterInput.textDidChange()
        lastHashCount = field.stringValue.reduce(0) { $0 + ($1 == "#" || $1 == "＃" ? 1 : 0) }
    }

    /// # を打ったら稲妻を一瞬反転させる（アクセントの面に地の色の稲妻、140ms）。光やにじみは使わない
    func flashBolt() {
        guard let v = boltView, let l = v.layer else { return }
        l.backgroundColor = K.cg(K.accent, in: v)
        v.contentTintColor = K.panel
        DispatchQueue.main.asyncAfter(deadline: .now() + K.tBase) { [weak v] in
            guard let v else { return }
            v.layer?.backgroundColor = nil
            v.contentTintColor = K.accent
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if filterInput.handle(sel) { return true }
        switch sel {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(verticalStep(1))
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(verticalStep(-1))
            return true
        // 2 列のカードの間は ←→ で左右に動く（カードを選んでいて、入力欄のカーソルが末尾にあるときだけ）
        case #selector(NSResponder.moveLeft(_:)) where onCard && textView.selectedRange().location == (textView.string as NSString).length:
            moveSelection(-1)
            return true
        case #selector(NSResponder.moveRight(_:)) where onCard && textView.selectedRange().location == (textView.string as NSString).length:
            moveSelection(1)
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
        tv.selectedTextAttributes = [.backgroundColor: K.selBg, .foregroundColor: K.selFg]
        tv.markedTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: PanelStyle.caret]
        tv.onEdit = { [weak self] in self?.updatePlaceholder() }
        return tv
    }()

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? NSTextField) === field ? bandEditor : nil
    }
}
