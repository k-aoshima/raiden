import AppKit
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
    static let glassTint = NSColor(white: 1, alpha: 0.55)   // ガラスの白寄りの色
    static let veil = NSColor(white: 1, alpha: 0.62)        // ガラスが使えない／描かれない時も白く見せる面
    static let selection = NSColor(srgbRed: 0.0, green: 0.42, blue: 1.0, alpha: 0.12)
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
    var onClick: (() -> Void)?
    var selected = false { didSet { needsDisplay = true; hint.isHidden = !selected } }

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
        for v in [icon, title, sub, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30), icon.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -10),
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
}

/// アイコンと文字の 1 行（節の見出し・「見つかりません」）。選べない
final class LabelLine: NSView {
    init(_ text: String, symbol name: String, detail: String? = nil, big: Bool = false) {
        super.init(frame: .zero)
        let glyph = NSImageView(image: symbol(name, size: big ? 15 : 10, weight: .semibold) ?? NSImage())
        glyph.contentTintColor = big ? PanelStyle.subText : PanelStyle.faint
        let label = NSTextField(labelWithString: text)
        label.font = big ? .systemFont(ofSize: 14, weight: .semibold) : .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = big ? PanelStyle.text : PanelStyle.faint
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

    var path: String {
        switch self {
        case .app(let r): return r.app.path
        case .file(let r): return r.file.path
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

    init(_ c: Candidate) {
        candidate = c
        iconPath = c.path
        switch c {
        case .app(let r):
            title = r.app.jp == r.app.name ? r.app.jp : "\(r.app.jp)  \(r.app.name)"
            sub = (r.app.path as NSString).abbreviatingWithTildeInPath
            hint = RowItem.appHint
        case .file(let r):
            title = r.file.name
            sub = RowItem.shortParent(r.file.path)
            hint = r.file.isDir ? RowItem.folderHint : RowItem.fileHint
        }
    }

    init(title: String, sub: String, iconPath: String? = nil, iconImage: NSImage? = nil, hint: String) {
        self.title = title; self.sub = sub; self.iconPath = iconPath; self.iconImage = iconImage; self.hint = hint
    }

    static let appHint = "↩ 開く　⌘↩ Finder"
    static let fileHint = "↩ 開く　⌘↩ Finder に表示"
    static let folderHint = "↩ Finder で開く　⌘↩ 場所を表示"

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
    private let stack = NSStackView()
    private var rows: [ResultRow] = []
    private var lines: [NSView] = []
    private var results: [RowItem] = []
    private var selected = 0
    private var iconCache: [String: NSImage] = [:]
    private var heightConstraint: NSLayoutConstraint!
    /// 絞り込みのコマンド（-kind ss -date 7d）の一覧・チップ・ゴーストテキスト（FilterUI.swift）
    let filterInput = FilterInput()
    var selectedRow: Int { selected }

    /// maxRows はアプリ＋ファイルの合計
    static let width: CGFloat = 660, fieldHeight: CGFloat = 60, rowHeight: CGFloat = 48, headerHeight: CGFloat = 26,
               messageHeight: CGFloat = 52, maxRows = 9

    var onQuery: ((String) -> Void)?
    /// (入力, 候補, ⌘ を押していたか)。⌘Enter は Finder に表示
    var onOpen: ((String, Candidate, Bool) -> Void)?
    var onHide: (() -> Void)?

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
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
            glass.style = .regular
            glass.cornerRadius = PanelStyle.radius
            glass.tintColor = PanelStyle.glassTint
            glass.contentView = content
            panel.contentView = glass
        } else {
            let bg = NSVisualEffectView()
            bg.material = .popover
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
        }
        content.appearance = PanelStyle.appearance

        let glyph = NSImageView(image: symbol("magnifyingglass", size: 20, weight: .medium) ?? NSImage())
        glyph.contentTintColor = PanelStyle.subText
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .regular)
        field.textColor = PanelStyle.text
        field.placeholderAttributedString = NSAttributedString(
            string: "アプリ・ファイルを探す（例: PDFを見るやつ）",
            attributes: [.foregroundColor: PanelStyle.faint, .font: NSFont.systemFont(ofSize: 24)])
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        statusIcon.contentTintColor = PanelStyle.faint
        status.font = .systemFont(ofSize: 12)
        status.textColor = PanelStyle.subText
        status.alignment = .right
        let sep = HairlineView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading

        for v in [veil, glyph, field, statusIcon, status, sep, stack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        heightConstraint = stack.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            veil.topAnchor.constraint(equalTo: content.topAnchor), veil.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            veil.leadingAnchor.constraint(equalTo: content.leadingAnchor), veil.trailingAnchor.constraint(equalTo: content.trailingAnchor),
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
            stack.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            heightConstraint,
        ])
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // ⌘Enter は入力欄の doCommandBy に来ないことがあるので、ここで拾う（日本語入力の変換中は触らない）
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.panel.isKeyWindow,
                  ev.keyCode == 36 || ev.keyCode == 76,
                  ev.modifierFlags.contains(.command) else { return ev }
            if let tv = self.panel.firstResponder as? NSTextView, tv.hasMarkedText() { return ev }
            self.openSelected(reveal: true)
            return nil
        }
        filterInput.attach(self, field: field, content: content)
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        field.stringValue = ""
        filterInput.reset()
        setResults([], query: "")
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        onHide?()
    }

    /// 入力欄の右の状態（準備中など）。symbol は SF Symbols の名前
    func setStatus(_ s: String, symbol name: String? = nil) {
        status.stringValue = s
        statusIcon.image = s.isEmpty ? nil : name.flatMap { symbol($0, size: 12, weight: .medium) }
    }

    /// 見本を撮るとき用（入力欄の文字を入れる）
    func setQueryText(_ s: String) { field.stringValue = s }

    private func layoutPanel(height inner: CGFloat) {
        heightConstraint.constant = inner
        let h = Self.fieldHeight + (inner > 0 ? inner + 16 : 0)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 上端の位置を固定して下に伸ばす（候補の数で入力欄が動かないように）
        let top = vf.maxY - vf.height * 0.22
        panel.setFrame(NSRect(x: vf.midX - Self.width / 2, y: top - h, width: Self.width, height: h), display: true)
    }

    /// 節ごとに並べる。中身のある節が 1 つだけなら見出しは出さない。
    /// notFound: 出している節が全部見つからない（Engine の判定）。「見つかりません」を出し、候補は薄く下に並べる。
    /// 節ごとの印（ResultSection.faded）は、その節の候補だけ薄くして見出しに「見つかりません」を添える
    /// extra: 一番上に足す行（絞り込みの一覧の見出し）。palette: 絞り込みの一覧（出ている間は検索の結果で上書きしない）
    func setResults(_ sections: [ResultSection], query: String, notFound: Bool = false,
                    extra: [(NSView, CGFloat)] = [], palette: Bool = false) {
        guard query == filterInput.currentQuery, palette || filterInput.palette == nil else { return }
        let secs = sections.filter { !$0.items.isEmpty }
        let showHeaders = secs.count > 1 || notFound
        results = []
        selected = 0
        rows.forEach { $0.removeFromSuperview() }
        lines.forEach { $0.removeFromSuperview() }
        rows = []
        lines = []
        var inner: CGFloat = 0
        func addLine(_ v: NSView, _ h: CGFloat) {
            v.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
            v.heightAnchor.constraint(equalToConstant: h).isActive = true
            lines.append(v)
            inner += h
        }
        let top = palette ? extra : filterInput.topLines(sections: secs, query: query, preparing: !status.stringValue.isEmpty)
        for (v, h) in top { addLine(v, h) }
        if notFound && !query.isEmpty {
            addLine(LabelLine("見つかりません", symbol: "magnifyingglass", detail: secs.isEmpty ? nil : "近いものを薄く出しています", big: true),
                    Self.messageHeight)
        }
        for sec in secs {
            // 全体が見つからないときは上に大きく出しているので、節の見出しには添えない
            let fadeNote = sec.faded && !notFound ? "見つかりません" : nil
            if showHeaders || fadeNote != nil { addLine(LabelLine(sec.title, symbol: sec.symbol, detail: fadeNote), Self.headerHeight) }
            for item in sec.items {
                let i = results.count
                results.append(item)
                let row = ResultRow()
                row.translatesAutoresizingMaskIntoConstraints = false
                row.title.stringValue = item.title
                row.sub.stringValue = item.sub
                row.hint.stringValue = item.hint
                row.icon.image = item.iconImage ?? item.iconPath.map(icon)
                row.alphaValue = notFound || sec.faded ? 0.5 : 1
                row.onClick = { [weak self] in self?.selected = i; self?.openSelected(reveal: false) }
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
                rows.append(row)
                inner += Self.rowHeight
            }
        }
        updateSelection()
        layoutPanel(height: inner)
    }

    /// 見本を撮るとき用（選択を動かす）
    func select(_ i: Int) {
        guard rows.indices.contains(i) else { return }
        selected = i
        updateSelection()
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
        for (i, r) in rows.enumerated() { r.selected = i == selected }
    }

    private func openSelected(reveal: Bool) {
        guard results.indices.contains(selected), let c = results[selected].candidate else { return }
        let q = QueryFilters.parse(filterInput.currentQuery).text   // 覚えるのはコマンドを抜いた言葉
        hide()
        onOpen?(q, c, reveal)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        filterInput.textDidChange()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if filterInput.handle(sel) { return true }
        switch sel {
        case #selector(NSResponder.moveDown(_:)):
            if !rows.isEmpty { selected = (selected + 1) % rows.count; updateSelection() }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if !rows.isEmpty { selected = (selected - 1 + rows.count) % rows.count; updateSelection() }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // 日本語入力の変換中の Enter は確定に使う（ここには来ない）
            openSelected(reveal: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
}
