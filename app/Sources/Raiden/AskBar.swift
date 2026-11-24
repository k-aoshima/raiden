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
        head.font = K.mono(11.5, bold: true)
        head.textColor = K.accent
        head.lineBreakMode = .byTruncatingTail
        // 選ぶと何件になるか（「3〜41 件になります」）を薄い字で添える
        let counts = split.options.filter { !$0.replaces && $0.count >= 0 }.map(\.count)
        if split.total > 0, let lo = counts.min(), let hi = counts.max() {
            let a = NSMutableAttributedString(string: head.stringValue, attributes: [.font: head.font!, .foregroundColor: K.accent])
            let range = lo == hi ? FilterCompletion.countText(lo) : "\(FilterCompletion.countText(lo))〜\(FilterCompletion.countText(hi))"
            a.append(NSAttributedString(string: "　\(range) 件になります", attributes: [
                .font: K.read(11.5), .foregroundColor: K.dim]))
            head.attributedStringValue = a
        }
        let icon = NSImageView(image: symbol("questionmark.circle", size: 12) ?? NSImage())
        icon.contentTintColor = K.accent
        var pills: [NSView] = []
        // 一番効く案（選ぶと半分くらいに減る案。少なすぎず多すぎない）を藍の枠で強め、コマンドを添える（打ち方を覚えられるように）
        let half = Double(split.total) / 2
        let hot = split.total > 0 ? split.options.indices.filter { !split.options[$0].replaces && split.options[$0].count > 0 }
            .min { abs(Double(split.options[$0].count) - half) < abs(Double(split.options[$1].count) - half) } : nil
        for (i, o) in split.options.enumerated() {
            // count が負なら件数を出さない（⌘→ の「基準に探す」）
            let n = o.count < 0 ? nil : (o.count >= 1000 && o.replaces ? "1000以上" : FilterCompletion.countText(o.count))
            let p = AskPill(key: "⌘\(i + 1)", label: o.label, count: n, command: i == hot ? o.command : nil, hot: i == hot)
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
        // 罫線の枠（角は丸めない）。問いなので面は薄いアクセント
        let r = NSRect(x: 10.5, y: 3.5, width: bounds.width - 21, height: bounds.height - 11)
        K.accentBg.setFill()
        r.fill()
        K.rule.setStroke()
        let p = NSBezierPath(rect: r)
        p.lineWidth = 1
        p.stroke()
    }
}

/// 問いの選び先 1 つ: 四角に「⌘1」のキーの札（反転）・名前・件数（hot ならアクセントの 2px の枠とコマンド）
final class AskPill: TapPill {
    private let hot: Bool

    init(key: String, label: String, count: String?, command: String?, hot: Bool) {
        self.hot = hot
        super.init(frame: .zero)
        let k = NSTextField(labelWithString: key)
        k.font = K.mono(11.5, bold: true)
        k.textColor = K.selFg
        let kb = KFill(K.selBg)
        k.translatesAutoresizingMaskIntoConstraints = false
        kb.addSubview(k)
        NSLayoutConstraint.activate([
            k.leadingAnchor.constraint(equalTo: kb.leadingAnchor, constant: 4), k.trailingAnchor.constraint(equalTo: kb.trailingAnchor, constant: -4),
            k.topAnchor.constraint(equalTo: kb.topAnchor, constant: 0), k.bottomAnchor.constraint(equalTo: kb.bottomAnchor, constant: 0),
        ])
        let l = NSTextField(labelWithString: label)
        l.font = K.read(12.5)
        l.textColor = K.fg
        l.lineBreakMode = .byTruncatingMiddle
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [kb, l]
        if let count {
            let c = NSTextField(labelWithString: count)
            c.font = K.mono(11.5)
            c.textColor = K.dim
            views.append(c)
        }
        if let command {
            let c = NSTextField(labelWithString: command)
            c.font = K.mono(11.5)
            c.textColor = K.accent
            views.append(c)
        }
        let st = NSStackView(views: views)
        st.spacing = 6
        st.alignment = .centerY
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        NSLayoutConstraint.activate([
            st.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9), st.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            st.topAnchor.constraint(equalTo: topAnchor, constant: 5), st.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(rect: bounds.insetBy(dx: hot ? 1 : 0.5, dy: hot ? 1 : 0.5))
        K.panel.setFill()
        bounds.fill()
        (hot ? K.accent : K.ui).setStroke()
        p.lineWidth = hot ? 2 : 1
        p.stroke()
    }
}
