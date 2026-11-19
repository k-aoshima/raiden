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
    /// ファイル一覧の作り直し（初回のベクトル化は数十秒かかるので、検索の列とは分ける）と、ファイルを選んだ例の保存。
    /// FileIndex はこの列からだけ触る
    private let fileWork = DispatchQueue(label: "raiden.files", qos: .utility)
    /// アプリを選んだ例の保存（Store がファイルのベクトル化で塞がっていても、検索の列を止めないように分ける）
    private let learnWork = DispatchQueue(label: "raiden.learn", qos: .utility)
    private var generation = 0
    private var pendingQuery: DispatchWorkItem?
    /// 入力が止まってから検索するまでの待ち
    private static let debounce: TimeInterval = 0.1
    private var fileIndex: FileIndex?
    private var fileWatcher: FSWatcher?
    private var appWatcher: FSWatcher?
    /// 一度でもファイル一覧ができたか（それまでは「ファイル準備中…」でアプリだけ出す）
    private var filesReady = false
    /// 取りこぼしの保険の全体の見直し（ふだんは FSEvents で変化をすぐ拾う）
    private static let fullScanInterval: TimeInterval = 86400
    private var unloadTimer: Timer?
    private var unloadItems: [NSMenuItem] = []
    private let defaults = UserDefaults.standard

    /// 入力欄を閉じてから何分でモデルを解放するか（0 = 解放しない）
    private var unloadMinutes: Int {
        get { defaults.object(forKey: "unloadAfterMinutes") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "unloadAfterMinutes") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        LoginItem.syncAtLaunch()
        setupStatusItem()
        setupHotKey()
        panel.onQuery = { [weak self] q in self?.query(q) }
        panel.onOpen = { [weak self] q, c, reveal in self?.open(q, c, reveal: reveal) }
        panel.onHide = { [weak self] in self?.scheduleUnload() }
        panel.filterInput.context = { [weak self] in self?.filesReady == true ? self?.engine?.filterContext : nil }
        panel.setStatus("準備中…", symbol: "hourglass")
        work.async { [weak self] in self?.boot() }
        // 取りこぼしの保険（1 日 1 回、アプリもファイルも全体を見直す）
        Timer.scheduledTimer(withTimeInterval: Self.fullScanInterval, repeats: true) { [weak self] _ in
            self?.rescan()
            self?.fullScanFiles()
        }
    }

    // MARK: 起動

    private func boot() {
        let t0 = Date()
        do {
            let dir = Bundle.main.resourceURL!.appendingPathComponent("model")
            let b = try BGEEmbedder(modelDir: dir, body: "body.mlmodelc", computeUnits: .cpuOnly)
            try b.load()
            let store = try Store()
            // 入力文と例のベクトルは覚えておく（ファイル一覧を作り直すたびに例を入れ直すため）
            let e = Engine(embedder: CachedEmbedder(b), store: store)
            let opens = OpenWithIndex.build()
            e.setApps(AppCatalog.collect(opens: opens), opens: opens)
            e.loadExamples()
            bge = b
            engine = e
            let msg = String(format: "起動 %.1fs  アプリ %d  例 %d  メモリ %.0fMB",
                             Date().timeIntervalSince(t0), e.apps.count, e.examples.count, physFootprintMB())
            NSLog("Raiden: %@", msg)
            DispatchQueue.main.async {
                self.panel.setStatus("ファイル準備中…", symbol: "hourglass")
                self.startWatching(e)
                self.fullScanFiles()
            }
        } catch {
            NSLog("Raiden: 起動に失敗 %@", "\(error)")
            DispatchQueue.main.async { self.panel.setStatus("モデルを読めませんでした", symbol: "exclamationmark.triangle") }
        }
    }

    private func rescan() {
        work.async { [weak self] in
            guard let e = self?.engine else { return }
            let opens = OpenWithIndex.build()
            e.setApps(AppCatalog.collect(opens: opens), opens: opens)
        }
    }

    /// FSEvents で見張り始める。全体の見直しより先に始めるので、見直しの間の変化も後で拾える
    private func startWatching(_ e: Engine) {
        let idx = FileIndex(engine: e)
        fileIndex = idx
        fileWatcher = FSWatcher(paths: idx.roots) { [weak self] change in
            self?.fileWork.async {
                let st = idx.apply(change)
                NSLog("Raiden: ファイルの変化 %d 件・削除 %d 件（ベクトル化 %d 件）%.2fs",
                      st.changed, st.removed, st.embedded, st.seconds)
            }
        }
        // アプリの場所はフォルダ単位で十分（.app の中の細かい変化はまとめて 1 回の取り直しになる）
        appWatcher = FSWatcher(paths: AppCatalog.dirs, fileEvents: false, quiet: 1.0, maxWait: 5.0) { [weak self] _ in
            self?.rescan()
        }
    }

    /// ファイル一覧を全体から作り直す（起動時と 1 日 1 回）。変わったものだけベクトル化する
    private func fullScanFiles() {
        guard let idx = fileIndex else { return }
        fileWork.async { [weak self] in
            let st = idx.fullScan { n in
                DispatchQueue.main.async {
                    if self?.filesReady == false { self?.panel.setStatus("ファイル準備中… \(n)", symbol: "hourglass") }
                }
            }
            NSLog("Raiden: ファイル %d 件（ベクトル化 %d 件、例 %d）%.1fs", st.changed, st.embedded, st.examples, st.seconds)
            DispatchQueue.main.async {
                guard let self, !self.filesReady else { return }
                self.filesReady = true
                self.panel.setStatus("")
            }
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
        // 解放していたら、打ち始める前に読み直しておく
        if let b = bge, !b.isLoaded {
            work.async {
                let s = (try? b.load()) ?? 0
                NSLog("Raiden: モデル再読み込み %.2fs", s)
            }
        }
    }

    // MARK: 検索と開く

    /// 入力のたびに呼ばれる。入力が止まって debounce 秒たってから検索し、古い問い合わせは捨てる
    private func query(_ q: String) {
        generation += 1
        let g = generation
        pendingQuery?.cancel()
        pendingQuery = nil
        if q.isEmpty { panel.setResults([], query: q); return }
        let withFiles = filesReady
        let item = DispatchWorkItem { [weak self] in
            self?.work.async {
                guard let self, let e = self.engine else { return }
                // 待っている間に次の文字が来ていたら捨てる
                var stale = false
                DispatchQueue.main.sync { stale = g != self.generation }
                if stale { return }
                let (sections, notFound) = Self.sections(q, engine: e, withFiles: withFiles)
                DispatchQueue.main.async {
                    if g == self.generation { self.panel.setResults(sections, query: q, notFound: notFound) }
                }
            }
        }
        pendingQuery = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: item)
    }

    /// アプリとファイルを節に分けて並べる（合計 maxRows 件）。
    /// 点数はアプリとファイルで付け方が違う（アプリは k近傍法の重み 1.0、ファイルは時間・種類・フォルダの加点）ので混ぜない。
    /// ふだんはアプリの節が先。時間・種類・つながりの言葉（「先週のPDF」「〜のとこ」）があればファイルの節を先にする。
    /// 先の節は最大 4 件、残りを後の節に回す（後の節が少なければ先の節に戻す）。
    /// 「見つからない」は Engine の印（searchJudged / searchFilesJudged）を節ごとに見る。
    /// 印の立った節は候補を薄くし、見出しに「見つかりません」を添える。
    /// 片方の節だけ印が立ったら、当たった節を先にする（「先週のPDF」でアプリが見つからないのは普通なので、全体は「見つかりません」にしない）。
    /// 出している節が全部見つからないときだけ、返り値の notFound を true にする（パネルは上に「見つかりません」を大きく出す）。
    static func sections(_ q: String, engine e: Engine, withFiles: Bool) -> ([ResultSection], Bool) {
        let total = SearchPanelController.maxRows
        let aj = e.searchJudged(q, limit: total)
        var appSec = ResultSection(title: "アプリ", symbol: "app.badge", items: aj.results.map { RowItem(.app($0)) })
        appSec.faded = aj.noMatch
        guard withFiles else { return ([appSec], aj.noMatch && !appSec.items.isEmpty) }
        let fj = e.searchFilesJudged(q, limit: total)
        var fileSec = ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: fj.results.map { RowItem(.file($0)) })
        fileSec.faded = fj.noMatch
        let it = QueryIntent.parse(q)
        var fileFirst = !it.isEmpty || it.hasRelation
        if aj.noMatch != fj.noMatch { fileFirst = aj.noMatch }
        var first = fileFirst ? fileSec : appSec, second = fileFirst ? appSec : fileSec
        let firstMax = 4
        let nSecond = min(second.items.count, total - min(first.items.count, firstMax))
        let nFirst = min(first.items.count, total - nSecond)
        first.items = Array(first.items.prefix(nFirst))
        second.items = Array(second.items.prefix(nSecond))
        let shown = [first, second].filter { !$0.items.isEmpty }
        let notFound = !shown.isEmpty && shown.allSatisfy(\.faded)
        return ([first, second], notFound)
    }

    private func open(_ q: String, _ c: Candidate, reveal: Bool) {
        let ws = NSWorkspace.shared
        switch c {
        case .app(let r):
            if reveal {
                ws.selectFile(r.app.path, inFileViewerRootedAtPath: "")
            } else {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                ws.openApplication(at: URL(fileURLWithPath: r.app.path), configuration: cfg) { _, err in
                    if let err { NSLog("Raiden: 開けませんでした %@", "\(err)") }
                }
            }
            learnWork.async { [weak self] in self?.engine?.learn(query: q, app: r.app) }
        case .file(let r):
            let url = URL(fileURLWithPath: r.file.path)
            if reveal {
                ws.selectFile(r.file.path, inFileViewerRootedAtPath: "")
            } else if r.file.isDir, let finder = ws.urlForApplication(withBundleIdentifier: "com.apple.finder") {
                // フォルダは既定のアプリに関係なく Finder で開く
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                ws.open([url], withApplicationAt: finder, configuration: cfg) { _, err in
                    if let err { NSLog("Raiden: 開けませんでした %@", "\(err)") }
                }
            } else if let appURL = ws.urlForApplication(toOpen: url) {
                // 開くアプリを先に決めて開き、その組を覚える（file → app の opened_with の線）
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                ws.open([url], withApplicationAt: appURL, configuration: cfg) { [weak self] _, err in
                    if let err { NSLog("Raiden: 開けませんでした %@", "\(err)"); return }
                    self?.fileWork.async { self?.engine?.recordOpened(file: r.file.path, appURL: appURL) }
                }
            } else if !ws.open(url) {
                NSLog("Raiden: 開けませんでした %@", r.file.path)
            }
            learnFile(q, r.file)
        }
    }

    /// 「入力 → ファイル」を例として保存し、メモリの Corpus にも足す（次から k近傍法で効く）。
    /// Engine にはファイル用の保存が無いので Store に記録し、メモリへは addFileExamples で入れる。
    /// ファイル一覧の作り直し（setFiles）と順番が入れ違わないよう、同じ列で行う
    private func learnFile(_ query: String, _ f: FileEntry) {
        let q = query.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let e = engine else { return }
        fileWork.async {
            let v = e.embedder.embed(q)
            e.store?.recordFileChoice(query: q, path: f.path, isDir: f.isDir, name: f.name, vector: v, model: e.embedder.identifier)
            e.addFileExamples([(q, f.path)])
        }
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
        let login = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isOn ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Raiden を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openPanel() { toggle() }
    @objc private func rescanNow() { rescan() }
    @objc private func toggleLogin(_ s: NSMenuItem) {
        LoginItem.set(s.state != .on)
        s.state = LoginItem.isOn ? .on : .off
    }
    @objc private func setUnload(_ s: NSMenuItem) {
        unloadMinutes = s.tag
        unloadItems.forEach { $0.state = $0.tag == s.tag ? .on : .off }
    }
}

// Raiden --snapshot <dir>: 入力欄の見本を PNG に書き出して終わる（画面には出さない）
if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "docs/ui"
    Snapshot.run(dir: dir)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
