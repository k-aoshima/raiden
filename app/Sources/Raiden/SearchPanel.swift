import AppKit
import RaidenCore

/// 入力欄を持てる枠なしパネル
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 候補 1 行（アイコン・名前・場所）。選択中は面の色だけで示す。
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
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingMiddle
        hint.font = .systemFont(ofSize: 12, weight: .medium)
        hint.textColor = .secondaryLabelColor
        hint.stringValue = "開く ↩"
        hint.isHidden = true
        for v in [icon, title, sub, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32), icon.heightAnchor.constraint(equalToConstant: 32),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -8),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -8),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// 節の見出し（「アプリ」「ファイル」）。選べない
final class SectionHeader: NSView {
    init(_ text: String, symbol: String) {
        super.init(frame: .zero)
        let glyph = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: text) ?? NSImage())
        glyph.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        glyph.contentTintColor = .tertiaryLabelColor
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        for v in [glyph, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
        ])
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

/// 一覧の 1 節（見出し＋候補）
struct ResultSection {
    var title: String
    var symbol: String
    var items: [Candidate]
}

/// 中央に出る入力欄と候補の一覧
final class SearchPanelController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    let panel: KeyPanel
    private let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var rows: [ResultRow] = []
    private var headers: [SectionHeader] = []
    private var results: [Candidate] = []
    private var selected = 0
    private var iconCache: [String: NSImage] = [:]
    private var heightConstraint: NSLayoutConstraint!

    /// maxRows はアプリ＋ファイルの合計
    static let width: CGFloat = 640, fieldHeight: CGFloat = 56, rowHeight: CGFloat = 46, headerHeight: CGFloat = 24, maxRows = 9

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
        panel.delegate = self

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 16
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        let glyph = NSImageView(image: NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Raiden")!)
        glyph.symbolConfiguration = .init(pointSize: 20, weight: .semibold)
        glyph.contentTintColor = .controlAccentColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .regular)
        field.placeholderString = "アプリ・ファイルを探す（例: PDFを見るやつ）"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        let sep = NSBox()
        sep.boxType = .separator
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading

        for v in [glyph, field, status, sep, stack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(v)
        }
        heightConstraint = stack.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 18),
            glyph.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: status.leadingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            status.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            status.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            sep.topAnchor.constraint(equalTo: bg.topAnchor, constant: Self.fieldHeight),
            sep.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            heightConstraint,
        ])
        status.setContentCompressionResistancePriority(.required, for: .horizontal)

        // ⌘Enter は入力欄の doCommandBy に来ないことがあるので、ここで拾う（日本語入力の変換中は触らない）
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.panel.isKeyWindow,
                  ev.keyCode == 36 || ev.keyCode == 76,
                  ev.modifierFlags.contains(.command) else { return ev }
            if let tv = self.panel.firstResponder as? NSTextView, tv.hasMarkedText() { return ev }
            self.openSelected(reveal: true)
            return nil
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        field.stringValue = ""
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

    func setStatus(_ s: String) { status.stringValue = s }

    private func layoutPanel(rows n: Int, headers hn: Int) {
        let inner = CGFloat(n) * Self.rowHeight + CGFloat(hn) * Self.headerHeight
        heightConstraint.constant = n > 0 ? inner : 0
        let h = Self.fieldHeight + (n > 0 ? inner + 10 : 0)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        // 上端の位置を固定して下に伸ばす（候補の数で入力欄が動かないように）
        let top = vf.maxY - vf.height * 0.22
        panel.setFrame(NSRect(x: vf.midX - Self.width / 2, y: top - h, width: Self.width, height: h), display: true)
    }

    /// 節ごとに並べる。中身のある節が 1 つだけなら見出しは出さない
    func setResults(_ sections: [ResultSection], query: String) {
        guard query == field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let secs = sections.filter { !$0.items.isEmpty }
        let showHeaders = secs.count > 1
        results = []
        selected = 0
        rows.forEach { $0.removeFromSuperview() }
        headers.forEach { $0.removeFromSuperview() }
        rows = []
        headers = []
        for sec in secs {
            if showHeaders {
                let h = SectionHeader(sec.title, symbol: sec.symbol)
                h.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(h)
                h.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
                h.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true
                headers.append(h)
            }
            for c in sec.items {
                let i = results.count
                results.append(c)
                let row = ResultRow()
                row.translatesAutoresizingMaskIntoConstraints = false
                switch c {
                case .app(let r):
                    row.title.stringValue = r.app.jp == r.app.name ? r.app.jp : "\(r.app.jp)  \(r.app.name)"
                    row.sub.stringValue = r.app.path
                    row.hint.stringValue = "開く ↩"
                case .file(let r):
                    row.title.stringValue = r.file.name
                    row.sub.stringValue = Self.shortParent(r.file.path)
                    row.hint.stringValue = r.file.isDir ? "Finder で開く ↩" : "開く ↩　Finder ⌘↩"
                }
                row.icon.image = icon(c.path)
                row.onClick = { [weak self] in self?.selected = i; self?.openSelected(reveal: false) }
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
                rows.append(row)
            }
        }
        updateSelection()
        layoutPanel(rows: rows.count, headers: headers.count)
    }

    /// 親フォルダまでのパスを ~ で短くする（~/Documents/仕事）
    static func shortParent(_ path: String) -> String {
        ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
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
        guard results.indices.contains(selected) else { return }
        let q = field.stringValue
        let r = results[selected]
        hide()
        onOpen?(q, r, reveal)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        onQuery?(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
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
