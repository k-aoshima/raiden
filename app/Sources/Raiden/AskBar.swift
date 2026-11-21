import AppKit
import RaidenCore

/// 窓の下の端の 1 行: 候補が多いときの絞り込みの問い（「86 件 · 時期で絞り込む  ⌘1 先月 41  ⌘2 …」）。
/// 上の候補を押し下げないよう一覧の下に置き、検索の結果が届いたとき（打つのを止めたとき）だけ出す。
/// 選び先は ⌘1〜⌘4 か押して決める（数字キーは検索の文字として打てるまま）。決めると打ったときと同じチップになる
final class AskBar: NSView {
    static let height: CGFloat = 40

    init(_ split: RecallSplit, onPick: @escaping (Int) -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        let stack = ChipBar.row(in: self)
        let head = NSTextField(labelWithString: split.total > 0 ? "\(FilterCompletion.countText(split.total)) 件 · \(split.title)" : split.title)
        head.font = .systemFont(ofSize: 11.5, weight: .semibold)
        head.textColor = PanelStyle.indigo
        let icon = NSImageView(image: symbol("questionmark.circle", size: 11, weight: .semibold) ?? NSImage())
        icon.contentTintColor = PanelStyle.indigo
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(head)
        stack.setCustomSpacing(10, after: head)
        for (i, o) in split.options.enumerated() {
            let n = o.count >= 1000 && o.replaces ? "1000以上" : FilterCompletion.countText(o.count)
            let p = ChipBar.pill("⌘\(i + 1)  \(o.label)  \(n)", symbol: o.symbol, filled: false)
            p.onTap = { onPick(i) }
            p.toolTip = "\(o.command)（⌘\(i + 1)）"
            stack.addArrangedSubview(p)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 10, dy: 4)
        let p = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        PanelStyle.indigo.withAlphaComponent(0.08).setFill()
        p.fill()
    }
}
