import AppKit
import Carbon
import CoreML
import RaidenCore

/// メニューバー常駐。ホットキーで入力欄を出し、曖昧な言い方でアプリを探して開く。
/// 選んで開いた組は raiden.sqlite に例として残り、次から k近傍法で効く。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let panel = SearchPanelController()
    private var hotKey: HotKey?
    private var hotKeyLabel = ""
    private var engine: Engine?
    private var bge: BGEEmbedder?
    private let work = DispatchQueue(label: "raiden.work", qos: .userInitiated)
    private var generation = 0
    private var lastScan = Date.distantPast
    private var unloadTimer: Timer?
    private var unloadItems: [NSMenuItem] = []
    private let defaults = UserDefaults.standard

    /// 入力欄を閉じてから何分でモデルを解放するか（0 = 解放しない）
    private var unloadMinutes: Int {
        get { defaults.object(forKey: "unloadAfterMinutes") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "unloadAfterMinutes") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        setupStatusItem()
        setupHotKey()
        panel.onQuery = { [weak self] q in self?.query(q) }
        panel.onOpen = { [weak self] q, r in self?.open(q, r) }
        panel.onHide = { [weak self] in self?.scheduleUnload() }
        panel.setStatus("準備中…")
        work.async { [weak self] in self?.boot() }
        // アプリの追加・削除を拾う（10 分おき）
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.rescan() }
    }

    // MARK: 起動

    private func boot() {
        let t0 = Date()
        do {
            let dir = Bundle.main.resourceURL!.appendingPathComponent("model")
            let b = try BGEEmbedder(modelDir: dir, body: "body.mlmodelc", computeUnits: .cpuOnly)
            try b.load()
            let store = try Store()
            let e = Engine(embedder: b, store: store)
            let opens = OpenWithIndex.build()
            e.setApps(AppCatalog.collect(opens: opens), opens: opens)
            e.loadExamples()
            bge = b
            engine = e
            lastScan = Date()
            let msg = String(format: "起動 %.1fs  アプリ %d  例 %d  メモリ %.0fMB",
                             Date().timeIntervalSince(t0), e.apps.count, e.examples.count, physFootprintMB())
            NSLog("Raiden: %@", msg)
            DispatchQueue.main.async { self.panel.setStatus("") }
        } catch {
            NSLog("Raiden: 起動に失敗 %@", "\(error)")
            DispatchQueue.main.async { self.panel.setStatus("モデルを読めませんでした") }
        }
    }

    private func rescan() {
        work.async { [weak self] in
            guard let self, let e = self.engine else { return }
            let opens = OpenWithIndex.build()
            e.setApps(AppCatalog.collect(opens: opens), opens: opens)
            self.lastScan = Date()
        }
    }

    // MARK: ホットキー

    private func setupHotKey() {
        // 既定は ⌥Space。⌃⌥Space は「入力ソースを切り替え」、⌃Space / ⌃⇧Space も入力ソース、
        // ⌘Space / ⌥⌘Space は Spotlight、Alfred は ⌥ の 2 度押しなので避けた。
        // 取れなければ ⌃⌥⌘Space に逃げる。
        let candidates: [(UInt32, UInt32, String)] = [
            (UInt32(kVK_Space), UInt32(optionKey), "⌥Space"),
            (UInt32(kVK_Space), UInt32(controlKey | optionKey | cmdKey), "⌃⌥⌘Space"),
        ]
        for (k, m, label) in candidates {
            if let hk = HotKey(keyCode: k, modifiers: m, action: { [weak self] in self?.toggle() }) {
                hotKey = hk
                hotKeyLabel = label
                break
            }
        }
        statusItem.menu?.item(at: 0)?.title = "Raiden を開く（\(hotKeyLabel)）"
        NSLog("Raiden: ホットキー %@", hotKeyLabel)
    }

    private func toggle() {
        if panel.isVisible { panel.hide(); return }
        unloadTimer?.invalidate()
        panel.show()
        if Date().timeIntervalSince(lastScan) > 600 { rescan() }
        // 解放していたら、打ち始める前に読み直しておく
        if let b = bge, !b.isLoaded {
            work.async {
                let s = (try? b.load()) ?? 0
                NSLog("Raiden: モデル再読み込み %.2fs", s)
            }
        }
    }

    // MARK: 検索と開く

    private func query(_ q: String) {
        generation += 1
        let g = generation
        if q.isEmpty { panel.setResults([], query: q); return }
        work.async { [weak self] in
            guard let self, let e = self.engine else { return }
            // 打っている途中の古い問い合わせは捨てる
            var stale = false
            DispatchQueue.main.sync { stale = g != self.generation }
            if stale { return }
            let rs = e.search(q, limit: SearchPanelController.maxRows)
            DispatchQueue.main.async {
                if g == self.generation { self.panel.setResults(rs, query: q) }
            }
        }
    }

    private func open(_ q: String, _ r: SearchResult) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: r.app.path), configuration: cfg) { _, err in
            if let err { NSLog("Raiden: 開けませんでした %@", "\(err)") }
        }
        work.async { [weak self] in self?.engine?.learn(query: q, app: r.app) }
    }

    // MARK: モデルの解放

    private func scheduleUnload() {
        unloadTimer?.invalidate()
        let m = unloadMinutes
        guard m > 0 else { return }
        unloadTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(m * 60), repeats: false) { [weak self] _ in
            guard let self, !self.panel.isVisible else { return }
            self.work.async {
                self.bge?.unload()
                NSLog("Raiden: モデルを解放 メモリ %.0fMB", physFootprintMB())
            }
        }
    }

    // MARK: メニュー

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Raiden")
        let menu = NSMenu()
        menu.addItem(withTitle: "Raiden を開く", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let sub = NSMenu()
        for (m, title) in [(0, "解放しない"), (5, "閉じて 5 分後"), (30, "閉じて 30 分後")] {
            let it = NSMenuItem(title: title, action: #selector(setUnload(_:)), keyEquivalent: "")
            it.target = self
            it.tag = m
            it.state = m == unloadMinutes ? .on : .off
            sub.addItem(it)
            unloadItems.append(it)
        }
        let parent = NSMenuItem(title: "モデルを解放", action: nil, keyEquivalent: "")
        parent.submenu = sub
        menu.addItem(parent)
        menu.addItem(withTitle: "アプリ一覧を更新", action: #selector(rescanNow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Raiden を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openPanel() { toggle() }
    @objc private func rescanNow() { rescan() }
    @objc private func setUnload(_ s: NSMenuItem) {
        unloadMinutes = s.tag
        unloadItems.forEach { $0.state = $0.tag == s.tag ? .on : .off }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
