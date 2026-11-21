import AppKit
import RaidenCore

/// 入力欄のすぐ下（チップの下・一覧の上）の絞り込みの問い。
///   1 行目: 「86 件 · 時期で絞り込む」
///   2 行目から: ⌘1 先月 41  ⌘2 …（窓の幅に入りきらなければ折り返す）
/// 選び先は ⌘1〜⌘4 か押して決める（数字キーは検索の文字として打てるまま）。決めると打ったときと同じチップになる
final class AskBar: NSView {
    private static let padX: CGFloat = 18, padY: CGFloat = 9, headH: CGFloat = 16, gap: CGFloat = 6, spacing: CGFloat = 6
    /// 中身に合わせた高さ（init で幅から決める）
    let preferredHeight: CGFloat

    override var isFlipped: Bool { true }

    init(_ split: RecallSplit, width: CGFloat, onPick: @escaping (Int) -> Void) {
        let head = NSTextField(labelWithString: split.total > 0 ? "\(FilterCompletion.countText(split.total)) 件 · \(split.title)" : split.title)
        head.font = .systemFont(ofSize: 11.5, weight: .semibold)
        head.textColor = PanelStyle.indigo
        head.lineBreakMode = .byTruncatingTail
        let icon = NSImageView(image: symbol("questionmark.circle", size: 11, weight: .semibold) ?? NSImage())
        icon.contentTintColor = PanelStyle.indigo
        var pills: [NSView] = []
        for (i, o) in split.options.enumerated() {
            let n = o.count >= 1000 && o.replaces ? "1000以上" : FilterCompletion.countText(o.count)
            let p = ChipBar.pill("⌘\(i + 1)  \(o.label)  \(n)", symbol: o.symbol, filled: false)
            p.onTap = { onPick(i) }
            p.toolTip = "\(o.command)（⌘\(i + 1)）"
            pills.append(p)
        }
        // 札を左から詰め、入らなければ次の行へ
        let maxX = width - Self.padX
        var frames: [NSRect] = []
        var x = Self.padX, y = Self.padY + Self.headH + Self.gap, rowH: CGFloat = 0
        for p in pills {
            var sz = p.fittingSize
            sz.width = min(sz.width, maxX - Self.padX)
            if x > Self.padX && x + sz.width > maxX { x = Self.padX; y += rowH + Self.spacing; rowH = 0 }
            frames.append(NSRect(x: x, y: y, width: sz.width, height: sz.height))
            x += sz.width + Self.spacing
            rowH = max(rowH, sz.height)
        }
        preferredHeight = (pills.isEmpty ? Self.padY + Self.headH : y + rowH) + Self.padY + 4   // 一覧の 1 行目とくっつかないよう下に 4
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: preferredHeight))
        wantsLayer = true
        let isz = icon.image?.size ?? .zero
        icon.frame = NSRect(x: Self.padX, y: Self.padY + (Self.headH - isz.height) / 2, width: isz.width, height: isz.height)
        let hx = Self.padX + isz.width + 5
        head.frame = NSRect(x: hx, y: Self.padY, width: maxX - hx, height: Self.headH)
        for v in [icon, head] as [NSView] + pills { v.translatesAutoresizingMaskIntoConstraints = true; addSubview(v) }
        for (p, f) in zip(pills, frames) { p.frame = f }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 10, y: 3, width: bounds.width - 20, height: bounds.height - 10)
        let p = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        PanelStyle.indigo.withAlphaComponent(0.08).setFill()
        p.fill()
    }
}
