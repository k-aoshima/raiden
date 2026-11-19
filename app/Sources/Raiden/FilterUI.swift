import AppKit
import RaidenCore

/// 入力欄の絞り込みコマンド（-kind ss -date 7d …）の画面側。SearchPanelController からは数か所だけ呼ぶ。
///
///   「-」を打つとコマンドの一覧、「-date 」で値の候補（件数つき）を候補の場所に出す。↑↓ で選び、Enter / Tab で決める。
///   値まで決まったコマンドはチップ（committed）にして入力欄から抜き、入力欄の下に並べる。入力欄が空のときの Backspace で最後のチップを消す。
///   打ちかけの値はゴーストテキスト（薄い文字）で補い、→ / Tab で決める。一覧が出ている間の Esc は一覧だけ閉じる。
final class FilterInput {
    weak var panel: SearchPanelController?
    private weak var field: NSTextField?
    /// 値まで決まったコマンド（"-date 7d"）。付けた順
    private(set) var committed: [String] = []
    private(set) var palette: FilterCompletion.Palette?
    private var ghost: (text: String, item: FilterCompletion.Item)?
    private var dismissedText: String?
    let ghostLabel = NSTextField(labelWithString: "")
    /// 値の候補の件数を数える一覧（AppDelegate が Engine.filterContext を渡す）
    var context: (() -> FilterContext?)?
    /// 見本・確かめ用の基準日
    var now: () -> Date = { Date() }

    func attach(_ panel: SearchPanelController, field: NSTextField, content: NSView) {
        self.panel = panel
        self.field = field
        ghostLabel.font = field.font
        ghostLabel.textColor = NSColor(white: 0.62, alpha: 1)
        ghostLabel.lineBreakMode = .byClipping
        ghostLabel.isHidden = true
        content.addSubview(ghostLabel)
    }

    func reset() {
        committed = []
        palette = nil
        ghost = nil
        dismissedText = nil
        ghostLabel.isHidden = true
    }

    /// 検索に渡す文字（チップ＋入力欄）。コマンドが無ければ今までどおり前後の空白を落とす。
    /// コマンドがあるときは後ろの空白を残す（打ちかけか打ち終えたかの見分けに使う）
    var currentQuery: String {
        let text = field?.stringValue ?? ""
        let raw = (committed + [text]).filter { !$0.isEmpty }.joined(separator: " ")
        let trimmedHead = String(raw.drop { $0.isWhitespace })
        if committed.isEmpty && !QueryFilters.parse(trimmedHead).hasSyntax {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmedHead
    }

    /// 入力が変わったとき（SearchPanelController.controlTextDidChange から）
    func textDidChange() {
        guard let field else { return }
        if let ex = FilterCompletion.extractCommitted(field.stringValue, now: now()) {
            committed += ex.commands
            field.stringValue = ex.text
            moveCaretToEnd()
        }
        refresh()
    }

    /// 一覧を出し直し、出さないときは検索する
    func refresh() {
        guard let field, let panel else { return }
        let text = field.stringValue
        if dismissedText != text { dismissedText = nil }
        palette = dismissedText == nil ? FilterCompletion.palette(for: text, committed: committed, context: context?(), now: now()) : nil
        ghost = palette.flatMap(FilterCompletion.ghost)
        updateGhost()
        if let p = palette {
            panel.setResults(paletteSections(p), query: currentQuery, extra: [paletteHeader(p)], palette: true)
        } else {
            panel.onQuery?(currentQuery)
        }
    }

    // MARK: キー

    /// 一覧・ゴースト・チップ用のキー。扱ったら true（SearchPanelController の doCommandBy の先頭で呼ぶ）
    func handle(_ sel: Selector) -> Bool {
        guard let field, let panel else { return false }
        let atEnd = (field.currentEditor()?.selectedRange.location ?? 0) >= (field.stringValue as NSString).length
        if let p = palette {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                let items = displayed(p)
                if items.indices.contains(panel.selectedRow) { accept(items[panel.selectedRow], p) }
                return true
            case #selector(NSResponder.insertTab(_:)):
                if let g = ghost, panel.selectedRow == 0 { accept(g.item, p); return true }
                let items = displayed(p)
                if items.indices.contains(panel.selectedRow) { accept(items[panel.selectedRow], p) }
                return true
            case #selector(NSResponder.moveRight(_:)):
                if let g = ghost, atEnd { accept(g.item, p); return true }
                return false
            case #selector(NSResponder.cancelOperation(_:)):
                dismissedText = field.stringValue
                refresh()
                return true
            default:
                break
            }
        }
        if sel == #selector(NSResponder.deleteBackward(_:)), field.stringValue.isEmpty, !committed.isEmpty {
            committed.removeLast()
            refresh()
            return true
        }
        return false
    }

    private func accept(_ item: FilterCompletion.Item, _ p: FilterCompletion.Palette) {
        guard let field else { return }
        let r = FilterCompletion.accept(item, palette: p, text: field.stringValue)
        if let c = r.commit { committed.append(c) }
        field.stringValue = r.text
        moveCaretToEnd()
        refresh()
    }

    /// 次に付けそうなコマンドを押したとき
    func acceptNext(_ insert: String) {
        committed.append(insert)
        refresh()
    }

    private func moveCaretToEnd() {
        guard let field, let ed = field.currentEditor() else { return }
        ed.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    // MARK: 見た目

    /// 件数のある値を先に、0 件は下に回す（行数は検索の候補と同じ 9 まで）
    private func displayed(_ p: FilterCompletion.Palette) -> [FilterCompletion.Item] {
        Array((p.items.filter { $0.count != 0 } + p.items.filter { $0.count == 0 }).prefix(SearchPanelController.maxRows))
    }

    private func paletteSections(_ p: FilterCompletion.Palette) -> [ResultSection] {
        let rows = displayed(p).map { it -> RowItem in
            var title = it.title
            if !it.alias.isEmpty { title += "    " + it.alias }
            if let c = it.count { title += "  ·  \(c) 件" }
            return RowItem(title: title, sub: it.detail, iconImage: symbol(it.symbol, size: 18, weight: .regular), hint: "↩ 選ぶ　Tab")
        }
        return [ResultSection(title: "候補", symbol: "list.bullet", items: rows)]
    }

    private func paletteHeader(_ p: FilterCompletion.Palette) -> (NSView, CGFloat) {
        let title: String
        switch p.mode {
        case .commands: title = "絞り込みのコマンド"
        case .values(let c): title = "\(c.name) の値" + (context?() == nil ? "" : "（件数はほかの条件の中で）")
        }
        return (LabelLine(title, symbol: "line.3.horizontal.decrease", detail: "↑↓ で選んで ↩ / Tab　Esc で閉じる"), SearchPanelController.headerHeight)
    }

    /// 入力欄の下に出す行（チップ・知らせ・次に付けそうなコマンド・「条件に合う物はありません」）。一覧を出していないときに使う
    func topLines(sections: [ResultSection], query: String, preparing: Bool) -> [(NSView, CGFloat)] {
        let f = QueryFilters.parse(query, now: now())
        guard f.hasSyntax else { return [] }
        var out: [(NSView, CGFloat)] = []
        let next = (field?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? false)
            ? FilterCompletion.next(f, context: context?(), now: now()) : []
        if !f.chips.isEmpty || !f.notes.isEmpty || !next.isEmpty {
            out.append((ChipBar(chips: f.chips, notes: f.notes, next: next) { [weak self] in self?.acceptNext($0) }, ChipBar.height))
        }
        if f.isActive && sections.allSatisfy({ $0.items.isEmpty }) {
            let msg = preparing && f.allowsFiles ? "ファイル準備中…" : "条件に合う物はありません"
            out.append((LabelLine(msg, symbol: "line.3.horizontal.decrease.circle", big: true), SearchPanelController.messageHeight))
        }
        return out
    }

    /// 打ちかけの値の後ろに薄い文字を出す（入力欄の文字の幅のすぐ右）
    func updateGhost() {
        guard let field, let g = ghost, let font = field.font else { ghostLabel.isHidden = true; return }
        let w = (field.stringValue as NSString).size(withAttributes: [.font: font]).width
        ghostLabel.stringValue = g.text
        ghostLabel.sizeToFit()
        let h = ghostLabel.frame.height
        ghostLabel.frame = NSRect(x: field.frame.minX + w + 2, y: field.frame.midY - h / 2,
                                  width: min(ghostLabel.frame.width, max(0, field.frame.maxX - field.frame.minX - w)), height: h)
        ghostLabel.isHidden = false
    }
}

/// 入力欄の下の 1 行: 効いている絞り込みのチップ（アイコン付き）、知らせ（「-size は使えません」）、次に付けそうなコマンド
final class ChipBar: NSView {
    static let height: CGFloat = 32
    private let onNext: (String) -> Void
    private var nextInserts: [String] = []

    init(chips: [QueryFilters.Chip], notes: [String], next: [FilterCompletion.Item], onNext: @escaping (String) -> Void) {
        self.onNext = onNext
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        for c in chips { stack.addArrangedSubview(Self.pill(c.label, symbol: c.symbol, filled: true)) }
        for n in notes {
            let l = NSTextField(labelWithString: n)
            l.font = .systemFont(ofSize: 11)
            l.textColor = NSColor(srgbRed: 0.75, green: 0.36, blue: 0.0, alpha: 1)
            let icon = NSImageView(image: symbol("exclamationmark.circle", size: 10, weight: .medium) ?? NSImage())
            icon.contentTintColor = l.textColor
            stack.addArrangedSubview(icon)
            stack.addArrangedSubview(l)
        }
        if !next.isEmpty {
            let l = NSTextField(labelWithString: "続けて")
            l.font = .systemFont(ofSize: 11)
            l.textColor = PanelStyle.faint
            stack.addArrangedSubview(l)
            for (i, it) in next.enumerated() {
                nextInserts.append(it.insert)
                let b = Self.pill(it.title + (it.count.map { " \($0)" } ?? ""), symbol: it.symbol, filled: false)
                let click = NSClickGestureRecognizer(target: self, action: #selector(tapNext(_:)))
                b.addGestureRecognizer(click)
                b.identifier = NSUserInterfaceItemIdentifier("\(i)")
                stack.addArrangedSubview(b)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapNext(_ g: NSClickGestureRecognizer) {
        guard let i = g.view?.identifier.flatMap({ Int($0.rawValue) }), nextInserts.indices.contains(i) else { return }
        onNext(nextInserts[i])
    }

    /// 札 1 つ（アイコン＋文字）。filled: 効いている絞り込み、false: 押すと足せる候補（枠だけ）
    static func pill(_ text: String, symbol name: String, filled: Bool) -> NSView {
        let v = PillView(filled: filled)
        let icon = NSImageView(image: symbol(name, size: 10, weight: .semibold) ?? NSImage())
        icon.contentTintColor = filled ? NSColor(srgbRed: 0.0, green: 0.36, blue: 0.85, alpha: 1) : PanelStyle.subText
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = filled ? PanelStyle.text : PanelStyle.subText
        for x in [icon, l] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            v.heightAnchor.constraint(equalToConstant: 22),
            icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            l.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            l.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -9),
        ])
        return v
    }
}

/// 札の面（角丸。効いている絞り込みは薄い青の面、候補は枠だけ）
final class PillView: NSView {
    let filled: Bool
    init(filled: Bool) { self.filled = filled; super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        if filled {
            NSColor(srgbRed: 0.0, green: 0.42, blue: 1.0, alpha: 0.10).setFill()
            p.fill()
        } else {
            NSColor(white: 0, alpha: 0.14).setStroke()
            p.lineWidth = 1
            p.stroke()
        }
    }
}

/// 見本の PNG（Raiden --snapshot <dir>）。手元のファイルは使わず、見本の一覧で件数を出す
enum FilterSnapshots {
    static func run(dir: String) {
        let home = NSHomeDirectory()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        let now = f.date(from: "2026-11-19 12:00")!
        func t(_ s: String) -> Int { Int(f.date(from: s)!.timeIntervalSince1970) }
        var files: [FileEntry] = []
        let days = ["2026-11-19 09:00", "2026-11-19 10:30", "2026-11-18 15:00", "2026-11-16 11:00", "2026-11-14 20:00",
                    "2026-11-10 09:00", "2026-11-03 12:00", "2026-10-20 12:00", "2026-10-02 12:00", "2026-09-15 12:00"]
        for (i, d) in days.enumerated() {
            files.append(FileEntry(path: home + "/Desktop/スクリーンショット サンプル\(i).png", mtime: t(d)))
            if i % 2 == 0 { files.append(FileEntry(path: home + "/Documents/サンプル/見積書_サンプル\(i).pdf", mtime: t(d))) }
            if i % 3 == 0 { files.append(FileEntry(path: home + "/Downloads/資料_サンプル\(i).docx", mtime: t(d))) }
        }
        files.append(FileEntry(path: home + "/Documents/サンプル", isDir: true, mtime: t("2026-11-19 09:00")))
        let ctx = FilterContext(files: files, appCount: 120)

        func panel(_ text: String, committed: [String] = []) -> SearchPanelController {
            let c = SearchPanelController()
            c.filterInput.context = { ctx }
            c.filterInput.now = { now }
            for x in committed { c.filterInput.acceptNext(x) }
            c.setQueryText(text)
            c.filterInput.refresh()
            return c
        }
        Snapshot.capture(panel("-"), dir + "/option-commands.png")
        Snapshot.capture(panel("-date "), dir + "/option-date-values.png")
        Snapshot.capture(panel("-kind sc"), dir + "/option-ghost.png")

        // チップが 2 つ付いた状態（-kind ss -date 7d）。候補は見本
        let c = panel("", committed: ["-kind ss", "-date 7d"])
        let rows = files.filter { QueryFilters.parse("-kind ss -date 7d", now: now).matches($0) }.prefix(4).map {
            RowItem(title: $0.name, sub: RowItem.shortParent($0.path), iconImage: NSWorkspace.shared.icon(for: .png), hint: RowItem.fileHint)
        }
        let q = c.filterInput.currentQuery
        c.setResults([ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: Array(rows))], query: q)
        Snapshot.capture(c, dir + "/option-chips.png")
    }
}
