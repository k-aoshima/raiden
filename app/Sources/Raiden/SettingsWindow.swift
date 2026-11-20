import AppKit
import RaidenCore
import UniformTypeIdentifiers

/// 一覧とベクトル化の状態（設定窓の「検索範囲」に出す）
struct IndexStatus {
    var count = 0
    /// まだベクトルの無い物を作っている（その間も名前の一致と絞り込みでは候補に出る）
    var embedding: (done: Int, total: Int)?
    /// 中身の頭を入れた説明文で作り直している（検索はもう全部に効く）
    var refining: (done: Int, total: Int)?
    var scanning = false
    var ready = false
}

/// 設定窓から呼ぶアプリ側の口（AppDelegate と、PNG の書き出し用のダミーが持つ）
protocol SettingsHost: AnyObject {
    var settings: RaidenSettings { get }
    /// 設定を変えて保存し、アプリに当てる
    func updateSettings(_ f: (inout RaidenSettings) -> Void)
    var indexStatus: IndexStatus { get }
    func rebuildIndex()
    /// フォルダの中の件数（数え終わっていなければ nil、数え始める）。数え終わったら then
    func folderCount(_ path: String, then: @escaping (ScopeCounter.Result) -> Void) -> ScopeCounter.Result?
    var hotKeyLabel: String { get }
    /// ホットキーを当てる（nil は既定）。登録できなければ理由を返す（前のキーに戻す）
    func applyHotKey(_ hk: RaidenSettings.HotKeySetting?) -> String?
    func suspendHotKey(_ on: Bool)
    var loginOn: Bool { get }
    func setLogin(_ on: Bool)
    func learnedExamples() -> [LearnedExample]
    func deleteLearned(_ e: LearnedExample)
    func clearLearned()
    func appNotes() -> [(String, String)]
    func saveAppNotes(_ notes: [(String, String)])
    func recentSearches() -> [SearchLogEntry]
    func notFoundSearches() -> [SearchLogEntry]
    func searchLogCount() -> Int
    func clearSearchLog()
    func openLogFolder()
    var logFolderPath: String { get }
    /// 見つからなかった言い方に正解を教える（NSOpenPanel で選ぶ）
    func teach(_ e: SearchLogEntry, completion: @escaping (String?) -> Void)
    /// 透け具合を入力欄に当てる（保存はしない。スライダーを動かしている間）
    func previewTransparency(_ t: Double)
    /// 検索の記録から数えた「#」のよく使う組み合わせ（学習タブに出す）
    func filterCombos() -> [FilterMemory.Combo]
}

extension SettingsHost {
    func filterCombos() -> [FilterMemory.Combo] { [] }
}

/// 左の一覧の 1 行（アイコン＋名前）。選択中は面の色だけ
final class SidebarItem: NSView {
    var selected = false { didSet { needsDisplay = true; label.textColor = selected ? SettingsStyle.text : SettingsStyle.subText; icon.contentTintColor = selected ? SettingsStyle.accent : SettingsStyle.subText } }
    var onClick: (() -> Void)?
    private let icon: NSImageView
    private let label: NSTextField

    init(title: String, symbol name: String) {
        icon = sIcon(name, size: 14, color: SettingsStyle.subText)
        label = sLabel(title, size: 13, weight: .medium, color: SettingsStyle.subText)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        SettingsStyle.selection.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// 白い面（透け具合に合わせて濃さを変える。draw で描くので PNG にも出る）
final class TintView: NSView {
    var alpha: CGFloat = 0.7 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: alpha).setFill()
        bounds.fill()
    }
}

/// 設定の窓（検索範囲・一般・学習・記録）
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTokenFieldDelegate {
    enum Tab: Int, CaseIterable {
        case scope, general, learning, log
        var title: String { ["検索範囲", "一般", "学習", "記録"][rawValue] }
        var symbol: String { ["folder.badge.gearshape", "gearshape", "brain", "list.bullet.rectangle"][rawValue] }
        var file: String { ["scope", "general", "learning", "log"][rawValue] }
    }

    let window: NSWindow
    weak var host: SettingsHost?
    private(set) var tab: Tab = .scope
    private var items: [SidebarItem] = []
    private let tint = TintView()
    private let paneHost = NSView()
    private var pane: NSView?
    // 検索範囲の画面の、状態だけ書き換える部品
    private var statusLabel: NSTextField?
    private var statusIcon: NSImageView?
    private var statusBar: NSProgressIndicator?
    /// 足したが件数が多すぎてオフのままにしたフォルダ
    private var largeOff: [String: Int] = [:]
    private var notesDraft: [(String, String)]?
    /// 学習タブの辞書・保存した絞り込みの編集中の値（SettingsLearning.swift）
    let learningState = LearningPaneState()
    private var hotKeyMessage: String?
    private var rebuildPending = false

    init(host: SettingsHost) {
        self.host = host
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsStyle.width, height: SettingsStyle.height),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Raiden 設定"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = SettingsStyle.appearance
        window.delegate = self

        // すりガラス（窓の後ろが透ける）の上に、透け具合に合わせた白い面を載せる。普通の窓として読みやすいよう、入力欄より白め
        let root = NSVisualEffectView()
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        root.appearance = SettingsStyle.appearance
        window.contentView = root

        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 2
        let sideLine = HairlineView()
        for v in [tint, sidebar, sideLine, paneHost] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        for t in Tab.allCases {
            let it = SidebarItem(title: t.title, symbol: t.symbol)
            it.onClick = { [weak self] in self?.select(t) }
            sidebar.addArrangedSubview(it)
            it.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
            items.append(it)
        }
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: root.topAnchor), tint.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: root.leadingAnchor), tint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            sidebar.widthAnchor.constraint(equalToConstant: SettingsStyle.sidebar - 24),
            sideLine.topAnchor.constraint(equalTo: root.topAnchor),
            sideLine.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sideLine.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: SettingsStyle.sidebar),
            sideLine.widthAnchor.constraint(equalToConstant: 1),
            paneHost.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            paneHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            paneHost.leadingAnchor.constraint(equalTo: sideLine.trailingAnchor),
            paneHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        applyTransparency(host.settings.transparency)
        select(.scope)
    }

    /// 透け具合を窓の白い面に当てる（0 → 0.92、0.9 → 0.61。入力欄より白めにして読みやすさを保つ）
    func applyTransparency(_ t: Double) {
        tint.alpha = CGFloat(0.92 - 0.35 * t)
    }

    func show(_ t: Tab? = nil) {
        if let t { select(t) } else { reload() }
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func select(_ t: Tab) {
        tab = t
        for (i, it) in items.enumerated() { it.selected = i == t.rawValue }
        reload()
    }

    /// 今の画面を作り直す
    func reload() {
        pane?.removeFromSuperview()
        statusLabel = nil; statusIcon = nil; statusBar = nil
        let content: [NSView]
        switch tab {
        case .scope: content = scopePane()
        case .general: content = generalPane()
        case .learning: content = learningPaneV2(learningState)
        case .log: content = logPane()
        }
        let v = scrollPane(content)
        paneHost.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: paneHost.topAnchor), v.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor), v.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
        ])
        pane = v
        refreshStatus()
    }

    /// 件数を数え終わったときなど。続けて来ても 1 回にまとめて作り直す（検索範囲の画面のときだけ）
    func scheduleReload() {
        guard !rebuildPending else { return }
        rebuildPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildPending = false
            if self.tab == .scope && self.window.isVisible { self.reload() }
        }
    }

    /// 一覧の状態が変わったとき（AppDelegate から）
    func refreshStatus() {
        guard let host, let label = statusLabel else { return }
        let st = host.indexStatus
        let nf = NumberFormatter(); nf.numberStyle = .decimal
        if let (d, t) = st.embedding {
            label.stringValue = "1/2 名前と場所で意味を登録中 \(nf.string(from: d as NSNumber) ?? "\(d)")/\(nf.string(from: t as NSNumber) ?? "\(t)")（終わると次は中身を読みます）"
            statusIcon?.image = symbol("arrow.triangle.2.circlepath", size: 14, weight: .medium)
            statusIcon?.contentTintColor = SettingsStyle.accent
            statusBar?.isHidden = false
            statusBar?.maxValue = Double(max(t, 1)); statusBar?.doubleValue = Double(d)
        } else if let (d, t) = st.refining, !st.scanning {
            label.stringValue = "2/2 PDF・文書の中身を読んで登録し直し中 \(nf.string(from: d as NSNumber) ?? "\(d)")/\(nf.string(from: t as NSNumber) ?? "\(t)")（検索はもう使えます）"
            statusIcon?.image = symbol("doc.text.magnifyingglass", size: 14, weight: .medium)
            statusIcon?.contentTintColor = SettingsStyle.subText
            statusBar?.isHidden = false
            statusBar?.maxValue = Double(max(t, 1)); statusBar?.doubleValue = Double(d)
        } else if st.scanning || !st.ready {
            label.stringValue = st.ready ? "見直しています…（\(nf.string(from: st.count as NSNumber) ?? "")件）" : "一覧を作っています…"
            statusIcon?.image = symbol("hourglass", size: 14, weight: .medium)
            statusIcon?.contentTintColor = SettingsStyle.subText
            statusBar?.isHidden = true
        } else {
            label.stringValue = "\(nf.string(from: st.count as NSNumber) ?? "\(st.count)") 件・最新"
            statusIcon?.image = symbol("checkmark.circle.fill", size: 14, weight: .medium)
            statusIcon?.contentTintColor = NSColor(srgbRed: 0.2, green: 0.65, blue: 0.35, alpha: 1)
            statusBar?.isHidden = true
        }
    }

    func windowWillClose(_ notification: Notification) {
        host?.suspendHotKey(false)
    }

    // MARK: - 画面の枠

    private func scrollPane(_ views: [NSView]) -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in views {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        doc.addSubview(stack)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -24),
        ])
        return scroll
    }

    func header(_ t: Tab, _ desc: String) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let ic = sIcon(t.symbol, size: 18, color: SettingsStyle.accent, weight: .semibold)
        let title = sLabel(t.title, size: 20, weight: .semibold)
        let d = sLabel(desc, size: 12, color: SettingsStyle.subText, wraps: true)
        for x in [ic, title, d] as [NSView] { v.addSubview(x) }
        NSLayoutConstraint.activate([
            ic.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            ic.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: ic.trailingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: v.topAnchor),
            d.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            d.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            d.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            d.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -6),
        ])
        return v
    }

    func card(_ rows: [NSView]) -> CardView {
        let c = CardView()
        for r in rows { c.add(r) }
        return c
    }

    func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    static let number: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; return f }()
    static func num(_ n: Int) -> String { number.string(from: n as NSNumber) ?? "\(n)" }

    static func date(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = Calendar.current.isDate(Date(timeIntervalSince1970: TimeInterval(ts)), equalTo: Date(), toGranularity: .year)
            ? "M/d HH:mm" : "yyyy/M/d"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private func folderIcon(_ path: String) -> NSImageView {
        let abs = RaidenSettings.Folder(path: path).absolutePath
        let img = FileManager.default.fileExists(atPath: abs) ? NSWorkspace.shared.icon(forFile: abs) : NSWorkspace.shared.icon(for: .folder)
        img.size = NSSize(width: 32, height: 32)
        let v = NSImageView(image: img)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 20).isActive = true
        v.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return v
    }

    private func chooseFolders(_ title: String) -> [String] {
        let p = NSOpenPanel()
        p.title = title
        p.prompt = "選ぶ"
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard p.runModal() == .OK else { return [] }
        return p.urls.map { RaidenSettings.tilde($0.path) }
    }

    // MARK: - 検索範囲

    private func scopePane() -> [NSView] {
        guard let host else { return [] }
        let s = host.settings
        var out: [NSView] = [header(.scope, "ファイル・フォルダを探す場所と、探さないもの。アプリを探す場所はいつも同じです。")]

        // 件数とベクトル化の状態
        let status = NSView()
        status.translatesAutoresizingMaskIntoConstraints = false
        let ic = sIcon("checkmark.circle.fill", size: 14)
        let l = sLabel("", size: 13, weight: .medium)
        let bar = NSProgressIndicator()
        bar.style = .bar; bar.isIndeterminate = false; bar.controlSize = .small; bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        let rebuild = sButton("今すぐ作り直す", symbol: "arrow.clockwise", small: true) { [weak self] in self?.host?.rebuildIndex() }
        for x in [ic, l, bar, rebuild] as [NSView] { status.addSubview(x) }
        NSLayoutConstraint.activate([
            status.heightAnchor.constraint(equalToConstant: 48),
            ic.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: 14),
            ic.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            l.leadingAnchor.constraint(equalTo: ic.trailingAnchor, constant: 8),
            l.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: rebuild.leadingAnchor, constant: -12),
            bar.widthAnchor.constraint(equalToConstant: 140),
            bar.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            rebuild.trailingAnchor.constraint(equalTo: status.trailingAnchor, constant: -14),
            rebuild.centerYAnchor.constraint(equalTo: status.centerYAnchor),
        ])
        statusLabel = l; statusIcon = ic; statusBar = bar
        out.append(card([status]))

        // 広すぎる場所の注意
        if let warn = scopeWarning(s) {
            let b = BannerView()
            b.label.stringValue = warn
            out.append(b)
        }

        // 探すフォルダ
        out.append(sectionTitle("検索するフォルダ", symbol: "folder",
                                trailing: [sButton("フォルダを追加…", symbol: "plus", small: true) { [weak self] in self?.addFolders() }]))
        let folders = CardView()
        for (i, f) in s.folders.enumerated() {
            let sw = sSwitch(f.enabled) { [weak self] on in
                self?.host?.updateSettings { $0.folders[i].enabled = on }
                if on { self?.largeOff[f.path] = nil }
                self?.reload()
            }
            let count = sLabel(countText(f.path), size: 11, color: SettingsStyle.subText)
            count.alignment = .right
            let del = sIconButton("minus.circle", tip: "一覧から外す") { [weak self] in
                self?.host?.updateSettings { $0.folders.remove(at: i) }
                self?.largeOff[f.path] = nil
                self?.reload()
            }
            folders.add(itemRow(icon: folderIcon(f.path), title: f.path, dim: !f.enabled, leading: [sw], trailing: [count, del]))
        }
        if s.folders.isEmpty { folders.add(formRow("tray", "フォルダがありません（ファイルは探しません）", iconColor: SettingsStyle.faint)) }
        out.append(folders)

        // 除くもの
        out.append(spacer(4))
        out.append(sectionTitle("除外するフォルダ", symbol: "folder.badge.minus",
                                trailing: [sButton("フォルダを追加…", symbol: "plus", small: true) { [weak self] in self?.addExcludeFolders() }]))
        let ex = CardView()
        for (i, p) in s.excludeFolders.enumerated() {
            let del = sIconButton("minus.circle", tip: "除外をやめる") { [weak self] in
                self?.host?.updateSettings { $0.excludeFolders.remove(at: i) }
                self?.reload()
            }
            ex.add(itemRow(icon: folderIcon(p), title: p, trailing: [del]))
        }
        if s.excludeFolders.isEmpty { ex.add(formRow("tray", "なし", iconColor: SettingsStyle.faint)) }
        out.append(ex)

        out.append(spacer(4))
        out.append(sectionTitle("除外する名前", symbol: "textformat"))
        let names = CardView()
        let tf = NSTokenField()
        tf.objectValue = s.excludeNames
        tf.tokenizingCharacterSet = CharacterSet(charactersIn: ", \n")
        tf.font = .systemFont(ofSize: 12)
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.placeholderString = "名前かパターン（例: node_modules  *.tmp）"
        tf.delegate = self
        tf.onAction { [weak self] c in self?.commitNames(c) }
        tf.cell?.wraps = true
        tf.cell?.isScrollable = false
        tf.preferredMaxLayoutWidth = SettingsStyle.width - SettingsStyle.sidebar - 48 - 24
        tf.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 10),
            tf.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -10),
            tf.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 12),
            tf.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -12),
            tf.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        names.add(wrap)
        names.add(formRow("info.circle", "隠しファイル・.app・パッケージの中はいつも除外します",
                          height: 34, iconColor: SettingsStyle.faint))
        out.append(names)
        return out
    }

    /// 行: 先頭の部品・アイコン・題（~/ のパス）・後ろの部品
    func itemRow(icon: NSView, title: String, detail: String? = nil, dim: Bool = false,
                         leading: [NSView] = [], trailing: [NSView]) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let lead = NSStackView(views: leading + [icon])
        lead.spacing = 10
        lead.translatesAutoresizingMaskIntoConstraints = false
        let t = sLabel(title, size: 13)
        t.textColor = dim ? SettingsStyle.faint : SettingsStyle.text
        let tools = NSStackView(views: trailing)
        tools.spacing = 10
        tools.translatesAutoresizingMaskIntoConstraints = false
        for x in [lead, t, tools] as [NSView] { row.addSubview(x) }
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tools.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: detail == nil ? 40 : 50),
            lead.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            lead.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            t.leadingAnchor.constraint(equalTo: lead.trailingAnchor, constant: 10),
            t.trailingAnchor.constraint(lessThanOrEqualTo: tools.leadingAnchor, constant: -12),
            tools.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            tools.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        if let detail {
            let d = sLabel(detail, size: 11, color: SettingsStyle.subText)
            d.lineBreakMode = .byTruncatingTail
            row.addSubview(d)
            d.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            NSLayoutConstraint.activate([
                t.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
                d.leadingAnchor.constraint(equalTo: t.leadingAnchor),
                d.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 2),
                d.trailingAnchor.constraint(lessThanOrEqualTo: tools.leadingAnchor, constant: -12),
            ])
        } else {
            t.centerYAnchor.constraint(equalTo: row.centerYAnchor).isActive = true
        }
        return row
    }

    private func countText(_ path: String) -> String {
        guard let host else { return "" }
        guard let r = host.folderCount(path, then: { [weak self] _ in self?.scheduleReload() }) else { return "数えています…" }
        if !FileManager.default.fileExists(atPath: RaidenSettings.Folder(path: path).absolutePath) { return "見つかりません" }
        return r.capped ? "\(Self.num(r.count)) 件以上" : "\(Self.num(r.count)) 件"
    }

    /// 広すぎる場所の注意（件数が数え終わっている分だけで見る）
    private func scopeWarning(_ s: RaidenSettings) -> String? {
        guard let host else { return nil }
        if let (p, n) = largeOff.first {
            let e = ScopeCounter.estimate(n)
            return "「\(p)」は \(Self.num(n)) 件\(n >= 200_000 ? "以上" : "")あるので、オフのまま追加しました。オンにすると、メモリが約 \(Self.num(e.memoryMB))MB、データベースが約 \(Self.num(e.dbMB))MB 増え、最初のベクトル作成に約 \(Self.num(e.minutes)) 分かかります（作成中も名前では探せます）。"
        }
        var total = 0
        for f in s.folders where f.enabled {
            guard let r = host.folderCount(f.path, then: { _ in }) else { continue }
            total += r.count
        }
        guard total > ScopeCounter.warnAbove else { return nil }
        let e = ScopeCounter.estimate(total)
        return "検索するのは合わせて約 \(Self.num(total)) 件です。5 万件を超えると、メモリが約 \(Self.num(e.memoryMB))MB、データベースが約 \(Self.num(e.dbMB))MB になり、最初のベクトル作成に約 \(Self.num(e.minutes)) 分かかります（作成中も名前では探せます）。狭いフォルダに分けるか、除外を足すのがおすすめです。"
    }

    private func addFolders() {
        guard let host else { return }
        for p in chooseFolders("検索するフォルダを選ぶ") where !host.settings.folders.contains(where: { $0.path == p }) {
            // 件数が分かるまではオフで足し、数え終わって多すぎなければオンにする
            host.updateSettings { $0.folders.append(.init(path: p, enabled: false)) }
            let decide: (ScopeCounter.Result) -> Void = { [weak self] r in
                DispatchQueue.main.async {
                    guard let self, let host = self.host, let i = host.settings.folders.firstIndex(where: { $0.path == p }) else { return }
                    var total = r.count
                    for f in host.settings.folders where f.enabled { total += host.folderCount(f.path, then: { _ in })?.count ?? 0 }
                    if r.count > ScopeCounter.warnAbove || total > ScopeCounter.warnAbove {
                        self.largeOff[p] = r.count
                    } else {
                        host.updateSettings { $0.folders[i].enabled = true }
                    }
                    self.reload()
                }
            }
            if let r = host.folderCount(p, then: decide) { decide(r) }
        }
        reload()
    }

    private func addExcludeFolders() {
        guard let host else { return }
        for p in chooseFolders("除外するフォルダを選ぶ") where !host.settings.excludeFolders.contains(p) {
            host.updateSettings { $0.excludeFolders.append(p) }
        }
        reload()
    }

    private func commitNames(_ c: NSControl) {
        guard let tf = c as? NSTokenField else { return }
        let names = ((tf.objectValue as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var uniq: [String] = []
        for n in names where !uniq.contains(n) { uniq.append(n) }
        guard uniq != host?.settings.excludeNames else { return }
        host?.updateSettings { $0.excludeNames = uniq }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let tf = obj.object as? NSTokenField { commitNames(tf) }
    }

    // MARK: - 一般

    private func generalPane() -> [NSView] {
        guard let host else { return [] }
        let s = host.settings
        var out: [NSView] = [header(.general, "入力欄の開き方と見え方。")]

        let rec = HotKeyRecorder(label: host.hotKeyLabel)
        rec.onBegin = { [weak self] in self?.host?.suspendHotKey(true) }
        rec.onEnd = { [weak self] in self?.host?.suspendHotKey(false) }
        rec.onRecord = { [weak self] hk in
            guard let self, let host = self.host else { return }
            if HotKeyInfo.conflictsWithSystem(keyCode: hk.keyCode, modifiers: hk.modifiers) {
                self.hotKeyMessage = "\(hk.label) はシステムのショートカットと重なっています（システム設定 → キーボード → ショートカット）。別のキーにしてください"
            } else if let err = host.applyHotKey(hk) {
                self.hotKeyMessage = err
            } else {
                self.hotKeyMessage = nil
            }
            self.reload()
        }
        let reset = sButton("初期値に戻す", symbol: "arrow.uturn.backward", small: true) { [weak self] in
            self?.hotKeyMessage = self?.host?.applyHotKey(nil)
            self?.reload()
        }
        let hkRow = formRow("keyboard", "入力欄を開くキー", detail: "クリックしてキーを押す（Esc でやめる）", trailing: [rec, reset], height: 56)

        let login = sSwitch(host.loginOn) { [weak self] on in self?.host?.setLogin(on) }
        let unloadValues = [0, 5, 30]
        var unloadTitles = ["解放しない", "閉じて 5 分後", "閉じて 30 分後"]
        var unloadSel = unloadValues.firstIndex(of: s.unloadMinutes) ?? -1
        if unloadSel < 0 { unloadTitles.append("閉じて \(s.unloadMinutes) 分後"); unloadSel = unloadTitles.count - 1 }
        let custom = s.unloadMinutes
        let unload = sPopup(unloadTitles, selected: unloadSel) { [weak self] i in
            let m = i < unloadValues.count ? unloadValues[i] : custom
            self?.host?.updateSettings { $0.unloadMinutes = m }
        }
        let rowsRange = Array(RaidenSettings.maxRowsRange)
        let maxRows = sPopup(rowsRange.map { "\($0) 件" }, selected: rowsRange.firstIndex(of: s.maxRows) ?? 4) { [weak self] i in
            self?.host?.updateSettings { $0.maxRows = rowsRange[i] }
        }
        let orders = SectionOrder.allCases
        let order = sPopup(orders.map(\.label), selected: orders.firstIndex(of: s.sectionOrder) ?? 0) { [weak self] i in
            self?.host?.updateSettings { $0.sectionOrder = orders[i] }
        }
        let pct = sLabel("\(Int((s.transparency * 100).rounded()))%", size: 12, color: SettingsStyle.subText)
        pct.widthAnchor.constraint(equalToConstant: 36).isActive = true
        pct.alignment = .right
        let slider = NSSlider(value: s.transparency, minValue: RaidenSettings.transparencyRange.lowerBound,
                              maxValue: RaidenSettings.transparencyRange.upperBound, target: nil, action: nil)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        slider.onAction { [weak self] c in
            let v = (c.doubleValue * 20).rounded() / 20
            pct.stringValue = "\(Int((v * 100).rounded()))%"
            self?.applyTransparency(v)
            self?.host?.previewTransparency(v)
            // 指を離したときだけ保存する
            if NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent == nil {
                self?.host?.updateSettings { $0.transparency = v }
            }
        }

        out.append(sectionTitle("入力欄", symbol: "magnifyingglass"))
        var hkRows: [NSView] = [hkRow]
        if let m = hotKeyMessage {
            let b = BannerView()
            b.label.stringValue = m
            let wrap = NSView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(b)
            NSLayoutConstraint.activate([
                b.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2), b.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -8),
                b.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 12), b.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -12),
            ])
            hkRows.append(wrap)
        }
        out.append(card(hkRows + [
            formRow("list.number", "候補の最大件数", detail: "アプリとファイルを合わせた数", trailing: [maxRows]),
            formRow("rectangle.split.1x2", "アプリとファイルの節の並び", detail: "自動は「先週のPDF」のような言い方でファイルを先にします", trailing: [order]),
            formRow("circle.lefthalf.filled", "透明度", detail: "上げるほど後ろが透けます", trailing: [slider, pct]),
        ]))
        out.append(spacer(4))
        out.append(sectionTitle("動作", symbol: "gearshape.2"))
        out.append(card([
            formRow("power", "ログイン時に起動", trailing: [login]),
            formRow("memorychip", "モデルを解放", detail: "閉じてしばらくでメモリを返す", trailing: [unload]),
        ]))
        return out
    }

    // MARK: - 学習

    /// app-notes の欄を打っている途中も下書きに残す（保存を押す前に再描画されても消えないように）
    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, !(f is NSTokenField), var d = notesDraft else { return }
        let i = f.tag / 2
        guard d.indices.contains(i) else { return }
        if f.tag % 2 == 0 { d[i].0 = f.stringValue } else { d[i].1 = f.stringValue }
        notesDraft = d
    }

    private func saveNotes() {
        window.makeFirstResponder(nil)
        guard let d = notesDraft else { return }
        let clean = d.map { ($0.0.trimmingCharacters(in: .whitespaces), $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.0.isEmpty && !$0.1.isEmpty }
        host?.saveAppNotes(clean)
        notesDraft = clean
        reload()
    }

    private func confirmClearLearned() {
        let a = NSAlert()
        a.messageText = "覚えた例を全部消しますか？"
        a.informativeText = "選んで開いた「言い方 → 物」の記録がすべて消え、元に戻せません。"
        a.addButton(withTitle: "全部消す")
        a.addButton(withTitle: "やめる")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        host?.clearLearned()
        reload()
    }

    // MARK: - 記録

    private func logPane() -> [NSView] {
        guard let host else { return [] }
        let s = host.settings
        var out: [NSView] = [header(.log, "検索の記録は、後で答え合わせや並べ方の調整に使う材料です。")]
        let privacy = formRow("lock.shield", "記録はこの Mac の中だけに残し、外へは送りません。", height: 30, iconColor: SettingsStyle.accent)
        out.append(privacy)

        let dayValues = [30, 90, 180, 365]
        var dayTitles = dayValues.map { "\($0) 日" }
        var daySel = dayValues.firstIndex(of: s.logDays) ?? -1
        if daySel < 0 { dayTitles.append("\(s.logDays) 日"); daySel = dayTitles.count - 1 }
        let customDays = s.logDays
        let days = sPopup(dayTitles, selected: daySel) { [weak self] i in
            let d = i < dayValues.count ? dayValues[i] : customDays
            self?.host?.updateSettings { $0.logDays = d }
        }
        let n = host.searchLogCount()
        out.append(card([
            formRow("record.circle", "検索の記録を残す", detail: "入力・途中の打ち直し・出した候補・選んだ物と順位・かかった時間",
                    trailing: [sSwitch(s.logSearches) { [weak self] on in self?.host?.updateSettings { $0.logSearches = on } }]),
            formRow("calendar", "残す日数", detail: "これより古い記録は自動で消します", trailing: [days]),
            formRow("doc.text", "動作の記録（raiden.log）", detail: host.logFolderPath,
                    trailing: [sButton("Finder で開く", symbol: "folder", small: true) { [weak self] in self?.host?.openLogFolder() }]),
            formRow("trash", "記録を全部消す", detail: "検索の記録 \(Self.num(n)) 件",
                    trailing: [sButton("全部消す", symbol: "trash", small: true) { [weak self] in self?.confirmClearLog() }]),
        ]))

        out.append(spacer(4))
        out.append(sectionTitle("最近の検索", symbol: "clock.arrow.circlepath"))
        let recent = ScrollList(maxHeight: 220, empty: "まだありません")
        recent.setRows(host.recentSearches().prefix(200).map { e in
            let name: String, sym: String
            if let c = e.chosenName, let r = e.chosenRank {
                name = r == 0 ? "「\(e.query)」 → \(c)（教えた）" : "「\(e.query)」 → \(c)（\(r)位）"
                sym = "checkmark.circle"
            } else {
                name = "「\(e.query)」"
                sym = "xmark.circle"
            }
            let icon = sIcon(sym, size: 13, color: e.chosenName == nil ? SettingsStyle.faint : SettingsStyle.subText)
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            var tools: [NSView] = []
            if e.notFound { tools.append(tag("見つかりません")) }
            tools.append(sLabel(Self.date(e.ts), size: 11, color: SettingsStyle.subText))
            return itemRow(icon: icon, title: name, trailing: tools)
        })
        out.append(recent)

        out.append(spacer(4))
        out.append(sectionTitle("見つからなかった言い方", symbol: "questionmark.circle"))
        let nf = ScrollList(maxHeight: 200, empty: "ありません")
        nf.setRows(host.notFoundSearches().prefix(200).map { e in
            let icon = sIcon("magnifyingglass", size: 13, color: SettingsStyle.faint)
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let teach = sButton("辞書に足す…", symbol: "book", small: true) { [weak self] in
                self?.addDictionary(phrase: e.query)
            }
            return itemRow(icon: icon, title: "「\(e.query)」", trailing: [sLabel(Self.date(e.ts), size: 11, color: SettingsStyle.subText), teach])
        })
        out.append(nf)
        return out
    }

    private func tag(_ s: String) -> NSView {
        let l = sLabel(s, size: 10, weight: .semibold, color: SettingsStyle.warn)
        let v = BannerTag(label: l)
        return v
    }

    private func confirmClearLog() {
        let a = NSAlert()
        a.messageText = "検索の記録を全部消しますか？"
        a.informativeText = "最近の検索と見つからなかった言い方の記録が消え、元に戻せません。辞書と選んで開いた記録は残ります。"
        a.addButton(withTitle: "全部消す")
        a.addButton(withTitle: "やめる")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        host?.clearSearchLog()
        reload()
    }

    // MARK: - PNG の書き出し用

    /// 画面に出さずに中身を撮る（Snapshot から）
    func snapshotContent() -> NSView? { window.contentView }

    /// 今の画面の中身の高さ（PNG を全部写すとき用）
    func contentHeight() -> CGFloat {
        guard let doc = (pane as? NSScrollView)?.documentView else { return SettingsStyle.height }
        doc.layoutSubtreeIfNeeded()
        return doc.fittingSize.height + 28
    }
}

/// 小さな札（「見つかりません」など）
final class BannerTag: NSView {
    init(label: NSTextField) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        SettingsStyle.warnFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}
