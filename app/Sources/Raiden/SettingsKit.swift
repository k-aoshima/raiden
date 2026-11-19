import AppKit
import ObjectiveC

/// 設定窓の色と部品。白基調（OS がダークモードでもライト）、選択は面の色だけ（左端の縦線は使わない）
enum SettingsStyle {
    static let appearance = PanelStyle.appearance
    static let text = PanelStyle.text
    static let subText = PanelStyle.subText
    static let faint = PanelStyle.faint
    static let accent = NSColor(srgbRed: 0.0, green: 0.42, blue: 1.0, alpha: 1)
    static let selection = PanelStyle.selection
    static let card = NSColor(white: 1, alpha: 0.78)
    static let cardStroke = NSColor(white: 0, alpha: 0.07)
    static let warnFill = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.0, alpha: 0.12)
    static let warn = NSColor(srgbRed: 0.75, green: 0.42, blue: 0.0, alpha: 1)
    static let danger = NSColor(srgbRed: 0.85, green: 0.2, blue: 0.2, alpha: 1)
    static let width: CGFloat = 760, height: CGFloat = 600, sidebar: CGFloat = 188
    static let cardRadius: CGFloat = 12
}

// MARK: - 閉包で受けるアクション

private final class ActionTarget: NSObject {
    let f: (NSControl) -> Void
    init(_ f: @escaping (NSControl) -> Void) { self.f = f }
    @objc func fire(_ s: NSControl) { f(s) }
}
private var actionKey: UInt8 = 0

extension NSControl {
    /// target-action を閉包で受ける（target は自分で持つ）
    func onAction(_ f: @escaping (NSControl) -> Void) {
        let t = ActionTarget(f)
        objc_setAssociatedObject(self, &actionKey, t, .OBJC_ASSOCIATION_RETAIN)
        target = t
        action = #selector(ActionTarget.fire(_:))
    }
}

// MARK: - 部品

func sLabel(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = SettingsStyle.text,
            wraps: Bool = false) -> NSTextField {
    let l = wraps ? NSTextField(wrappingLabelWithString: s) : NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    if !wraps { l.lineBreakMode = .byTruncatingMiddle }
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

func sIcon(_ name: String, size: CGFloat = 14, color: NSColor = SettingsStyle.subText, weight: NSFont.Weight = .medium) -> NSImageView {
    let v = NSImageView(image: symbol(name, size: size, weight: weight) ?? NSImage())
    v.contentTintColor = color
    v.translatesAutoresizingMaskIntoConstraints = false
    v.setContentHuggingPriority(.required, for: .horizontal)
    return v
}

/// アイコン付きの普通のボタン
func sButton(_ title: String, symbol name: String? = nil, small: Bool = false, _ f: @escaping () -> Void) -> NSButton {
    let b = NSButton(title: title, target: nil, action: nil)
    b.bezelStyle = .rounded
    if small { b.controlSize = .small; b.font = .systemFont(ofSize: 11) }
    if let name, let img = symbol(name, size: small ? 11 : 12, weight: .medium) {
        b.image = img
        b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    }
    b.onAction { _ in f() }
    b.translatesAutoresizingMaskIntoConstraints = false
    b.setContentHuggingPriority(.required, for: .horizontal)
    return b
}

/// 枠なしのアイコンだけのボタン（行の削除など）
func sIconButton(_ name: String, tip: String, color: NSColor = SettingsStyle.faint, _ f: @escaping () -> Void) -> NSButton {
    let b = NSButton(image: symbol(name, size: 13, weight: .medium) ?? NSImage(), target: nil, action: nil)
    b.isBordered = false
    b.contentTintColor = color
    b.toolTip = tip
    b.onAction { _ in f() }
    b.translatesAutoresizingMaskIntoConstraints = false
    b.setContentHuggingPriority(.required, for: .horizontal)
    return b
}

func sSwitch(_ on: Bool, _ f: @escaping (Bool) -> Void) -> NSSwitch {
    let s = NSSwitch()
    s.controlSize = .small
    s.state = on ? .on : .off
    s.onAction { c in f((c as? NSSwitch)?.state == .on) }
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
}

func sPopup(_ items: [String], selected: Int, _ f: @escaping (Int) -> Void) -> NSPopUpButton {
    let p = NSPopUpButton(frame: .zero, pullsDown: false)
    p.addItems(withTitles: items)
    p.selectItem(at: max(0, min(selected, items.count - 1)))
    p.controlSize = .small
    p.font = .systemFont(ofSize: 12)
    p.onAction { c in f((c as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
    p.translatesAutoresizingMaskIntoConstraints = false
    return p
}

/// 下が上から並ぶ入れ物（スクロールの中身用）
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 角の丸い白い面（中身を縦に並べる）
final class CardView: NSView {
    let stack = NSStackView()
    var fill = SettingsStyle.card { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = SettingsStyle.cardRadius
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        SettingsStyle.cardStroke.setStroke()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
        p.lineWidth = 1
        p.stroke()
    }

    /// 行を足す（行どうしの間に細い線）
    func add(_ v: NSView, separator: Bool = true) {
        if separator && !stack.arrangedSubviews.isEmpty {
            let line = HairlineView()
            line.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(line)
            NSLayoutConstraint.activate([
                line.heightAnchor.constraint(equalToConstant: 1),
                line.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
                line.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            ])
        }
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func removeAll() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }
}

/// 1 行: 左にアイコン・題・説明、右に操作の部品
func formRow(_ symbolName: String?, _ title: String, detail: String? = nil, trailing: [NSView] = [], height: CGFloat = 44,
             iconColor: NSColor = SettingsStyle.subText) -> NSView {
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false
    var lead = row.leadingAnchor
    var leadPad: CGFloat = 14
    if let symbolName {
        let ic = sIcon(symbolName, size: 13, color: iconColor)
        row.addSubview(ic)
        NSLayoutConstraint.activate([
            ic.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            ic.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ic.widthAnchor.constraint(equalToConstant: 18),
        ])
        lead = ic.trailingAnchor
        leadPad = 10
    }
    let t = sLabel(title, size: 13, weight: .regular)
    t.lineBreakMode = .byTruncatingTail
    row.addSubview(t)
    let tools = NSStackView(views: trailing)
    tools.orientation = .horizontal
    tools.spacing = 8
    tools.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(tools)
    tools.setContentCompressionResistancePriority(.required, for: .horizontal)
    t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    NSLayoutConstraint.activate([
        row.heightAnchor.constraint(equalToConstant: detail == nil ? height : max(height, 52)),
        t.leadingAnchor.constraint(equalTo: lead, constant: leadPad),
        t.trailingAnchor.constraint(lessThanOrEqualTo: tools.leadingAnchor, constant: -10),
        tools.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
        tools.centerYAnchor.constraint(equalTo: row.centerYAnchor),
    ])
    if let detail {
        let d = sLabel(detail, size: 11, color: SettingsStyle.subText)
        d.lineBreakMode = .byTruncatingTail
        row.addSubview(d)
        d.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            t.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
            d.leadingAnchor.constraint(equalTo: t.leadingAnchor),
            d.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 2),
            d.trailingAnchor.constraint(lessThanOrEqualTo: tools.leadingAnchor, constant: -10),
        ])
    } else {
        t.centerYAnchor.constraint(equalTo: row.centerYAnchor).isActive = true
    }
    return row
}

/// 節の見出し（アイコン＋小さめの太字）
func sectionTitle(_ s: String, symbol name: String, trailing: [NSView] = []) -> NSView {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    let ic = sIcon(name, size: 11, color: SettingsStyle.faint, weight: .semibold)
    let l = sLabel(s, size: 12, weight: .semibold, color: SettingsStyle.subText)
    let tools = NSStackView(views: trailing)
    tools.spacing = 6
    tools.translatesAutoresizingMaskIntoConstraints = false
    for x in [ic, l, tools] as [NSView] { v.addSubview(x) }
    NSLayoutConstraint.activate([
        v.heightAnchor.constraint(equalToConstant: 26),
        ic.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
        ic.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        l.leadingAnchor.constraint(equalTo: ic.trailingAnchor, constant: 6),
        l.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        tools.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        tools.centerYAnchor.constraint(equalTo: v.centerYAnchor),
    ])
    return v
}

/// 注意の帯（橙の薄い面＋アイコン）
final class BannerView: NSView {
    let label = sLabel("", size: 12, color: SettingsStyle.text, wraps: true)
    init(symbol name: String = "exclamationmark.triangle.fill") {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let ic = sIcon(name, size: 13, color: SettingsStyle.warn)
        addSubview(ic); addSubview(label)
        NSLayoutConstraint.activate([
            ic.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            ic.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            label.leadingAnchor.constraint(equalTo: ic.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        SettingsStyle.warnFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}

/// 中身の高さに合わせて伸び、maxHeight を超えたらスクロールする一覧
final class ScrollList: NSView {
    let card = CardView()
    private let scroll = NSScrollView()
    private var heightC: NSLayoutConstraint!
    let maxHeight: CGFloat
    let emptyText: String

    init(maxHeight: CGFloat, empty: String) {
        self.maxHeight = maxHeight
        self.emptyText = empty
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(card)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        heightC = heightAnchor.constraint(equalToConstant: 60)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            card.topAnchor.constraint(equalTo: doc.topAnchor), card.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: doc.leadingAnchor), card.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            heightC,
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setRows(_ rows: [NSView]) {
        card.removeAll()
        if rows.isEmpty {
            card.add(formRow("tray", emptyText, iconColor: SettingsStyle.faint), separator: false)
        } else {
            for r in rows { card.add(r) }
        }
        card.layoutSubtreeIfNeeded()
        let h = card.fittingSize.height
        heightC.constant = min(maxHeight, max(44, h))
    }
}
