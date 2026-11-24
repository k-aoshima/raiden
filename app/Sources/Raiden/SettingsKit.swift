import AppKit
import ObjectiveC

/// 設定窓の色と部品。中身は Kodou-ui の値（Kodou.swift の K）。選択は反転表示（左端の縦線は使わない）、角は丸めない
enum SettingsStyle {
    static var appearance: NSAppearance? { K.appearance }
    static var text: NSColor { K.fg }
    static var subText: NSColor { K.dim }
    static var faint: NSColor { K.faint }
    static var accent: NSColor { K.accent }
    static var selection: NSColor { K.selBg }
    static var card: NSColor { K.panel }
    static var cardStroke: NSColor { K.rule }
    static var warnFill: NSColor { K.yellowBg }
    static var warn: NSColor { K.yellow }
    static var danger: NSColor { K.red }
    static let width: CGFloat = 760, height: CGFloat = 600, sidebar: CGFloat = 188
    static let cardRadius: CGFloat = 0
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
    // 文は UD の読み書体（太さは 2 段）
    l.font = K.read(size, bold: weight.rawValue >= NSFont.Weight.semibold.rawValue)
    l.textColor = color
    if !wraps { l.lineBreakMode = .byTruncatingMiddle }
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

func sIcon(_ name: String, size: CGFloat = 14, color: NSColor = SettingsStyle.subText, weight: NSFont.Weight = .medium) -> NSImageView {
    let v = NSImageView(image: symbol(name, size: size, weight: weight) ?? NSImage())
    v.imageScaling = .scaleNone
    v.contentTintColor = color
    v.translatesAutoresizingMaskIntoConstraints = false
    v.setContentHuggingPriority(.required, for: .horizontal)
    return v
}

/// アイコン付きの普通のボタン（Kodou-ui のボタン: 1px の枠の四角、等幅の字、ホバーは地を薄く塗って枠を濃く）
func sButton(_ title: String, symbol name: String? = nil, small: Bool = false, _ f: @escaping () -> Void) -> NSButton {
    let b = KButton(title: title, symbol: name, small: small)
    b.onAction { _ in f() }
    return b
}

/// 枠なしのアイコンだけのボタン（行の削除など）。押せる範囲は 24pt
func sIconButton(_ name: String, tip: String, color: NSColor = SettingsStyle.faint, _ f: @escaping () -> Void) -> NSButton {
    let b = NSButton(image: symbol(name, size: 12) ?? NSImage(), target: nil, action: nil)
    b.isBordered = false
    b.imageScaling = .scaleNone
    b.contentTintColor = color
    b.toolTip = tip
    b.setAccessibilityLabel(tip)
    b.onAction { _ in f() }
    b.translatesAutoresizingMaskIntoConstraints = false
    b.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
    b.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
    b.setContentHuggingPriority(.required, for: .horizontal)
    return b
}

/// 入・切（Kodou-ui のスイッチ: [x] 入 / [ ] 切 の文字の印）
func sSwitch(_ on: Bool, _ f: @escaping (Bool) -> Void) -> NSButton {
    let s = KToggle(on: on)
    s.onAction { c in
        guard let t = c as? KToggle else { return }
        t.isOn.toggle()
        f(t.isOn)
    }
    return s
}

/// 決まった中から 1 つ（押すとメニュー）。見た目はボタンと同じ四角に「▾」
func sPopup(_ items: [String], selected: Int, _ f: @escaping (Int) -> Void) -> NSPopUpButton {
    let p = KPopup(frame: .zero, pullsDown: false)
    p.addItems(withTitles: items)
    p.selectItem(at: max(0, min(selected, items.count - 1)))
    p.onAction { c in f((c as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
    p.translatesAutoresizingMaskIntoConstraints = false
    return p
}

/// Kodou-ui のボタン
final class KButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    private let small: Bool

    init(title: String, symbol name: String?, small: Bool) {
        self.small = small
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        font = K.mono(small ? 11.5 : 12)
        if let name, let img = symbol(name, size: 12) {
            image = img
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            imageScaling = .scaleNone
        }
        contentTintColor = K.fg
        alignment = .center
        imageHugsTitle = true
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font!, .foregroundColor: K.fg])
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + (small ? 14 : 18), height: small ? 24 : 28)
    }
    override func draw(_ dirtyRect: NSRect) {
        if hovering { K.ruleSoft.setFill(); bounds.fill() }
        (hovering ? K.fg : K.ui).setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        p.lineWidth = 1
        p.stroke()
        super.draw(dirtyRect)
        if window?.firstResponder === self { KFocus.draw(around: bounds) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// Kodou-ui のスイッチ（[x] 入 / [ ] 切）
final class KToggle: NSButton {
    var isOn: Bool { didSet { refresh() } }
    init(on: Bool) {
        isOn = on
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityRole(.checkBox)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refresh() {
        let a = NSMutableAttributedString(string: isOn ? "[x]" : "[ ]", attributes: [
            .font: K.mono(12.5, bold: true), .foregroundColor: isOn ? K.accent : K.dim])
        a.append(NSAttributedString(string: isOn ? " 入" : " 切", attributes: [.font: K.mono(12.5), .foregroundColor: isOn ? K.fg : K.dim]))
        attributedTitle = a
        setAccessibilityValue(isOn)
        needsDisplay = true
    }
    override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width + 8, height: 24) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if window?.firstResponder === self { KFocus.draw(around: bounds) }
    }
}

/// Kodou-ui のセレクト（閉じた形はボタンと同じ四角）
final class KPopup: NSPopUpButton {
    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        isBordered = false
        font = K.mono(12)
        focusRingType = .none
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        let w = itemArray.map { ($0.title as NSString).size(withAttributes: [.font: font!]).width }.max() ?? 40
        return NSSize(width: ceil(w) + 40, height: 26)
    }
    override func draw(_ dirtyRect: NSRect) {
        K.panel.setFill()
        bounds.fill()
        K.ui.setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        p.lineWidth = 1
        p.stroke()
        let t = NSAttributedString(string: titleOfSelectedItem ?? "", attributes: [.font: font!, .foregroundColor: K.fg])
        let ts = t.size()
        t.draw(at: NSPoint(x: 10, y: (bounds.height - ts.height) / 2))
        let arrow = NSAttributedString(string: "▾", attributes: [.font: K.mono(12), .foregroundColor: K.dim])
        let asz = arrow.size()
        arrow.draw(at: NSPoint(x: bounds.width - asz.width - 9, y: (bounds.height - asz.height) / 2))
        if window?.firstResponder === self { KFocus.draw(around: bounds) }
    }
}

/// フォーカスの枠（アクセントの 2px の実線。点線にしない）
enum KFocus {
    static func draw(around r: NSRect) {
        K.accent.setStroke()
        let p = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
        p.lineWidth = 2
        p.stroke()
    }
}

/// Kodou-ui のテキスト入力（1px の枠、打っている間は枠をアクセントの 2px に）
final class KField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    convenience init(text: String) {
        self.init(frame: .zero)
        stringValue = text
    }
    required init?(coder: NSCoder) { fatalError() }
    override class var cellClass: AnyClass? { get { KFieldCell.self } set {} }
    private func setup() {
        isBezeled = false
        isBordered = false
        drawsBackground = true
        backgroundColor = K.panel
        textColor = K.fg
        font = K.mono(12)
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
    }
    override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width, height: 26) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let editing = currentEditor() != nil
        (editing ? K.accent : K.ui).setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: editing ? 1 : 0.5, dy: editing ? 1 : 0.5))
        p.lineWidth = editing ? 2 : 1
        p.stroke()
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); needsDisplay = true }
}

/// 文字を枠の内側に寄せる（左右 8・上下は真ん中）
final class KFieldCell: NSTextFieldCell {
    private func inner(_ r: NSRect) -> NSRect {
        let h = (font?.ascender ?? 10) - (font?.descender ?? -3) + 2
        return NSRect(x: r.minX + 8, y: r.minY + max(0, (r.height - h) / 2), width: r.width - 16, height: min(h, r.height))
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { inner(super.drawingRect(forBounds: rect)) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: inner(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: inner(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

/// 下が上から並ぶ入れ物（スクロールの中身用）
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 罫線の枠の面（中身を縦に並べる。角は丸めない）
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
        fill.setFill()
        bounds.fill()
        SettingsStyle.cardStroke.setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
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
    let ic = sIcon(name, size: 12, color: K.accent)
    let l = NSTextField(labelWithString: s)
    l.font = K.mono(12, bold: true)
    l.textColor = K.dim
    l.translatesAutoresizingMaskIntoConstraints = false
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

/// 注意の帯（薄い黄の面＋アイコン。左端に色の帯は付けない）
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
        bounds.fill()
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
