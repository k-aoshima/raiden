import AppKit
import Carbon
import CoreML
import RaidenCore

/// メニューバー常駐。ホットキーで入力欄を出し、曖昧な言い方でアプリを探して開く。
/// 選んで開いた組は raiden.sqlite に例として残り、次から k近傍法で効く。
/// 設定は ~/Library/Application Support/Raiden/settings.json（設定の窓で変える）。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let panel = SearchPanelController()
    private var hotKey: HotKey?
    private(set) var hotKeyLabel = ""
    private var engine: Engine?
    private var bge: BGEEmbedder?
    private var store: Store?
    private let work = DispatchQueue(label: "raiden.work", qos: .userInitiated)
    /// ファイル一覧の作り直し（初回のベクトル化は数十秒かかるので、検索の列とは分ける）と、ファイルを選んだ例の保存。
    /// FileIndex はこの列からだけ触る
    private let fileWork = DispatchQueue(label: "raiden.files", qos: .utility)
    /// アプリを選んだ例の保存（Store がファイルのベクトル化で塞がっていても、検索の列を止めないように分ける）
    private let learnWork = DispatchQueue(label: "raiden.learn", qos: .utility)
    /// 検索の記録の書き込み
    private let logWork = DispatchQueue(label: "raiden.searchlog", qos: .utility)
    /// 設定窓のフォルダの件数を数える
    private let countWork = DispatchQueue(label: "raiden.count", qos: .utility, attributes: .concurrent)
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
    private var loginItem: NSMenuItem?

    private(set) var settings = RaidenSettings()
    private var settingsWindow: SettingsWindowController?
    private(set) var indexStatus = IndexStatus()
    /// FileIndex に当てた範囲（設定を変えてから少し待って当てる）
    private var appliedScope: ScanScope?
    private var scopeApplyItem: DispatchWorkItem?
    private var countCache: [String: ScopeCounter.Result] = [:]
    private var countWaiters: [String: [(ScopeCounter.Result) -> Void]] = [:]
    private var countGen = 0

    /// 入力欄を開いてから閉じるまでの検索の記録（search_log の 1 行になる）
    private struct Session {
        var opened = Date()
        var edits: [SearchLogEntry.Edit] = []
        var query = ""
        var shown: [(Candidate, String)] = []   // 画面の並び順（候補, 節）
        var notFound = false, notFoundApps = false, notFoundFiles = false
        var ms: Double = 0
    }
    private var session: Session?

    func applicationDidFinishLaunching(_ n: Notification) {
        loadSettings()
        RaidenLog.shared.pruneOld()
        rlog("起動 版 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        LoginItem.syncAtLaunch()
        setupMainMenu()
        setupStatusItem()
        setupHotKey()
        panel.onQuery = { [weak self] q in self?.query(q) }
        panel.onOpen = { [weak self] q, c, reveal in self?.open(q, c, reveal: reveal) }
        panel.onHide = { [weak self] in
            self?.scheduleUnload()
            // 選んで閉じたときは open が先に記録する。残っていれば選ばずに閉じた
            DispatchQueue.main.async { self?.finishSession(chosen: nil) }
        }
        panel.filterInput.context = { [weak self] in self?.filesReady == true ? self?.engine?.filterContext : nil }
        panel.setStatus("準備中…", symbol: "hourglass")
        work.async { [weak self] in self?.boot() }
        // 取りこぼしの保険（1 日 1 回、アプリもファイルも全体を見直す）と、古い検索の記録の掃除
        Timer.scheduledTimer(withTimeInterval: Self.fullScanInterval, repeats: true) { [weak self] _ in
            self?.rescan()
            self?.fullScanFiles()
            self?.pruneSearchLog()
        }
    }

    // MARK: 設定

    private func loadSettings() {
        let exists = FileManager.default.fileExists(atPath: RaidenSettings.defaultURL.path)
        settings = RaidenSettings.load()
        // 前の版はモデルを解放する時間を UserDefaults に持っていた
        if !exists, let m = UserDefaults.standard.object(forKey: "unloadAfterMinutes") as? Int { settings.unloadMinutes = m }
        PanelStyle.transparency = settings.transparency
        SearchPanelController.maxRows = settings.maxRows
        panel.applyTransparency()
    }

    /// 設定を変えて保存し、変わった所をアプリに当てる
    func updateSettings(_ f: (inout RaidenSettings) -> Void) {
        var s = settings
        f(&s)
        guard s != settings else { return }
        let old = settings
        settings = s
        do { try s.save() } catch { rlogError("設定を保存できませんでした \(error)") }
        if old.excludeNames != s.excludeNames || old.excludeFolders != s.excludeFolders {
            countGen += 1; countCache = [:]; countWaiters = [:]
        }
        if old.scope != s.scope { scheduleScopeApply() }
        if old.transparency != s.transparency { previewTransparency(s.transparency) }
        if old.maxRows != s.maxRows { SearchPanelController.maxRows = s.maxRows }
        if old.unloadMinutes != s.unloadMinutes { unloadItems.forEach { $0.state = $0.tag == s.unloadMinutes ? .on : .off } }
        if old.logDays != s.logDays { pruneSearchLog() }
        if old.folders != s.folders || old.excludeFolders != s.excludeFolders || old.excludeNames != s.excludeNames {
            rlog("検索範囲を変更 探す \(s.scope.roots.map(RaidenSettings.tilde)) 除外フォルダ \(s.excludeFolders) 除外名 \(s.excludeNames)")
        }
    }

    func previewTransparency(_ t: Double) {
        PanelStyle.transparency = t
        panel.applyTransparency()
        settingsWindow?.applyTransparency(t)
    }

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(host: self) }
        settingsWindow?.show()
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
            let scope = DispatchQueue.main.sync { settings.scope }
            let opens = OpenWithIndex.build(scope: scope)
            e.setApps(AppCatalog.collect(opens: opens), opens: opens)
            e.loadExamples()
            bge = b
            self.store = store
            engine = e
            rlog(String(format: "モデル読み込み %.1fs  アプリ %d  例 %d  メモリ %.0fMB",
                        Date().timeIntervalSince(t0), e.apps.count, e.examples.count, physFootprintMB()))
            DispatchQueue.main.async {
                self.panel.setStatus("ファイル準備中…", symbol: "hourglass")
                // 読み込みの間に設定窓で範囲を変えていたら、今の設定で始める
                self.startWatching(e, scope: self.settings.scope)
                self.fullScanFiles()
                self.pruneSearchLog()
            }
        } catch {
            rlogError("起動に失敗 \(error)")
            DispatchQueue.main.async { self.panel.setStatus("モデルを読めませんでした", symbol: "exclamationmark.triangle") }
        }
    }

    private func rescan() {
        let scope = settings.scope
        work.async { [weak self] in
            guard let e = self?.engine else { return }
            let t = Date()
            let opens = OpenWithIndex.build(scope: scope)
            e.setApps(AppCatalog.collect(opens: opens), opens: opens)
            rlog(String(format: "アプリ一覧を作り直し %d 個 %.1fs", e.apps.count, Date().timeIntervalSince(t)))
        }
    }

    /// FSEvents で見張り始める。全体の見直しより先に始めるので、見直しの間の変化も後で拾える
    private func startWatching(_ e: Engine, scope: ScanScope) {
        let idx = FileIndex(engine: e, scope: scope)
        fileIndex = idx
        appliedScope = scope
        watchFiles(idx, roots: scope.roots)
        // アプリの場所はフォルダ単位で十分（.app の中の細かい変化はまとめて 1 回の取り直しになる）
        appWatcher = FSWatcher(paths: AppCatalog.dirs, fileEvents: false, quiet: 1.0, maxWait: 5.0) { [weak self] _ in
            self?.rescan()
        }
    }

    private func watchFiles(_ idx: FileIndex, roots: [String]) {
        fileWatcher?.stop()
        fileWatcher = FSWatcher(paths: roots) { [weak self] change in
            self?.fileWork.async {
                let st = idx.apply(change)
                if !st.rescanned.isEmpty {
                    rlog("FSEvents の履歴が途切れたので見直し \(st.rescanned.map(RaidenSettings.tilde))")
                }
                rlog(String(format: "ファイルの変化 %d 件・削除 %d 件（ベクトル化 %d 件）%.2fs", st.changed, st.removed, st.embedded, st.seconds))
                let n = idx.engine.files.count
                DispatchQueue.main.async { self?.indexStatus.count = n; self?.settingsWindow?.refreshStatus() }
            }
        }
    }

    /// ベクトル化の進み具合を入力欄と設定窓に出す
    private func progressHandler() -> (Int, Int) -> Void {
        { [weak self] d, t in
            DispatchQueue.main.async {
                guard let self else { return }
                self.indexStatus.embedding = d < t ? (d, t) : nil
                if !self.filesReady { self.panel.setStatus("ファイル準備中… \(d)/\(t)", symbol: "hourglass") }
                self.settingsWindow?.refreshStatus()
            }
        }
    }

    /// ファイル一覧を全体から作り直す（起動時と 1 日 1 回・設定の「今すぐ作り直す」）。変わったものだけベクトル化する
    private func fullScanFiles() {
        guard let idx = fileIndex else { return }
        indexStatus.scanning = true
        settingsWindow?.refreshStatus()
        let progress = progressHandler()
        fileWork.async { [weak self] in
            let st = idx.fullScan(progress: progress)
            rlog(String(format: "ファイル一覧を作り直し %d 件（ベクトル化 %d 件、例 %d）%.1fs", st.changed, st.embedded, st.examples, st.seconds))
            let n = idx.engine.files.count
            DispatchQueue.main.async {
                guard let self else { return }
                self.indexStatus = IndexStatus(count: n, embedding: nil, scanning: false, ready: true)
                self.settingsWindow?.refreshStatus()
                guard !self.filesReady else { return }
                self.filesReady = true
                self.panel.setStatus("")
            }
        }
    }

    /// 範囲を変えたら少し待ってから当てる（続けて変えたときにまとめる）
    private func scheduleScopeApply() {
        scopeApplyItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.applyScope() }
        scopeApplyItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    /// FileIndex の範囲を差し替え、FSEvents の見張りを張り直す。増えた場所だけベクトル化し（裏で）、
    /// 外した場所の点と線は SQLite から消える（FileIndex.setScope）。アプリの「いつも開く」も範囲に合わせて取り直す
    private func applyScope() {
        let scope = settings.scope
        guard let idx = fileIndex, scope != appliedScope else { return }
        appliedScope = scope
        watchFiles(idx, roots: scope.roots)
        indexStatus.scanning = true
        settingsWindow?.refreshStatus()
        let progress = progressHandler()
        fileWork.async { [weak self] in
            let st = idx.setScope(scope, progress: progress)
            rlog(String(format: "検索範囲を当てた 増えた %d 件・外した %d 件（ベクトル化 %d 件）%.1fs", st.changed, st.removed, st.embedded, st.seconds))
            let n = idx.engine.files.count
            DispatchQueue.main.async {
                guard let self else { return }
                self.indexStatus = IndexStatus(count: n, embedding: nil, scanning: false, ready: true)
                self.settingsWindow?.refreshStatus()
                self.rescan()
            }
        }
    }

    func rebuildIndex() { fullScanFiles() }

    func folderCount(_ path: String, then: @escaping (ScopeCounter.Result) -> Void) -> ScopeCounter.Result? {
        if let r = countCache[path] { return r }
        let first = countWaiters[path] == nil
        countWaiters[path, default: []].append(then)
        guard first else { return nil }
        let scope = settings.scope, gen = countGen
        let abs = RaidenSettings.Folder(path: path).absolutePath
        countWork.async { [weak self] in
            let r = ScopeCounter.count(root: abs, scope: scope)
            DispatchQueue.main.async {
                guard let self, gen == self.countGen else { return }
                self.countCache[path] = r
                let ws = self.countWaiters.removeValue(forKey: path) ?? []
                ws.forEach { $0(r) }
            }
        }
        return nil
    }

    // MARK: ホットキー

    private func setupHotKey() {
        registerHotKey()
        rlog("ホットキー \(hotKeyLabel)")
    }

    /// 設定のホットキーを登録する。設定が無ければ ⌥Space、取れなければ ⌃⌥⌘Space に逃げる。
    /// ⌃⌥Space は「入力ソースを切り替え」、⌃Space / ⌃⇧Space も入力ソース、⌘Space / ⌥⌘Space は Spotlight、
    /// Alfred は ⌥ の 2 度押しなので避けた。
    @discardableResult
    private func registerHotKey() -> Bool {
        hotKey = nil
        let candidates = settings.hotKey.map { [$0] } ?? [HotKeyInfo.defaultKey, HotKeyInfo.fallbackKey]
        for c in candidates {
            if let hk = HotKey(keyCode: c.keyCode, modifiers: c.modifiers, action: { [weak self] in self?.toggle() }) {
                hotKey = hk
                hotKeyLabel = c.label
                statusItem?.menu?.item(at: 0)?.title = "Raiden を開く（\(c.label)）"
                return true
            }
        }
        if settings.hotKey != nil {
            rlogError("ホットキー \(settings.hotKey!.label) を登録できなかったので初期値に戻す")
            settings.hotKey = nil
            return registerHotKey()
        }
        return false
    }

    func applyHotKey(_ hk: RaidenSettings.HotKeySetting?) -> String? {
        guard let hk else {
            updateSettings { $0.hotKey = nil }
            registerHotKey()
            rlog("ホットキーを初期値に戻した \(hotKeyLabel)")
            return nil
        }
        hotKey = nil
        if let k = HotKey(keyCode: hk.keyCode, modifiers: hk.modifiers, action: { [weak self] in self?.toggle() }) {
            hotKey = k
            hotKeyLabel = hk.label
            statusItem?.menu?.item(at: 0)?.title = "Raiden を開く（\(hk.label)）"
            updateSettings { $0.hotKey = hk }
            rlog("ホットキーを変更 \(hk.label)")
            return nil
        }
        registerHotKey()
        return "\(hk.label) はほかのアプリが使っていて登録できませんでした。別のキーにしてください"
    }

    /// キーを押して登録している間は、今のホットキーを外す（同じキーを押しても入力欄が開かないように）
    func suspendHotKey(_ on: Bool) {
        if on { hotKey = nil } else if hotKey == nil { registerHotKey() }
    }

    private func toggle() {
        if panel.isVisible { panel.hide(); return }
        unloadTimer?.invalidate()
        panel.show()
        session = Session()
        // 解放していたら、打ち始める前に読み直しておく
        if let b = bge, !b.isLoaded {
            work.async {
                let s = (try? b.load()) ?? 0
                rlog(String(format: "モデル再読み込み %.2fs", s))
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
        if var s = session, s.edits.last?.q != q {
            if s.edits.count < 100 { s.edits.append(.init(q: q, t: Int(Date().timeIntervalSince(s.opened) * 1000))) }
            s.query = q
            if q.isEmpty { s.shown = []; s.notFound = false; s.notFoundApps = false; s.notFoundFiles = false }
            session = s
        }
        if q.isEmpty { panel.setResults([], query: q); return }
        let withFiles = filesReady
        let order = settings.sectionOrder
        let item = DispatchWorkItem { [weak self] in
            self?.work.async {
                guard let self, let e = self.engine else { return }
                // 待っている間に次の文字が来ていたら捨てる
                var stale = false
                DispatchQueue.main.sync { stale = g != self.generation }
                if stale { return }
                let t0 = Date()
                let r = Self.sections(q, engine: e, withFiles: withFiles, order: order)
                let ms = Date().timeIntervalSince(t0) * 1000
                DispatchQueue.main.async {
                    guard g == self.generation else { return }
                    self.panel.setResults(r.sections, query: q, notFound: r.notFound)
                    if var s = self.session, s.query == q {
                        s.shown = r.sections.filter { !$0.items.isEmpty }.flatMap { sec in
                            sec.items.compactMap { $0.candidate.map { ($0, sec.symbol == "app.badge" ? "app" : "file") } }
                        }
                        s.notFound = r.notFound; s.notFoundApps = r.appsNoMatch; s.notFoundFiles = r.filesNoMatch
                        s.ms = ms
                        self.session = s
                    }
                }
            }
        }
        pendingQuery = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: item)
    }

    struct Sections {
        var sections: [ResultSection]
        var notFound: Bool
        var appsNoMatch: Bool
        var filesNoMatch: Bool
    }

    /// アプリとファイルを節に分けて並べる（合計 maxRows 件）。
    /// 点数はアプリとファイルで付け方が違う（アプリは k近傍法の重み 1.0、ファイルは時間・種類・フォルダの加点）ので混ぜない。
    /// 並び（設定の「一般」）が自動なら、ふだんはアプリの節が先。時間・種類・つながりの言葉（「先週のPDF」「〜のとこ」）があればファイルの節を先にする。
    /// 先の節は最大 4 件、残りを後の節に回す（後の節が少なければ先の節に戻す）。
    /// 「見つからない」は Engine の印（searchJudged / searchFilesJudged）を節ごとに見る。
    /// 印の立った節は候補を薄くし、見出しに「見つかりません」を添える。
    /// 自動のとき、片方の節だけ印が立ったら当たった節を先にする（「先週のPDF」でアプリが見つからないのは普通なので、全体は「見つかりません」にしない）。
    /// 出している節が全部見つからないときだけ notFound を true にする（パネルは上に「見つかりません」を大きく出す）。
    /// 絞り込みで全部出すときの上限（実質なし）
    static let allLimit = 100_000

    static func sections(_ q: String, engine e: Engine, withFiles: Bool, order: SectionOrder = .auto) -> Sections {
        // 絞り込みのコマンド（-type -kind -ext -date -path -name）が効いているときは上限で切らず全部出す（パネルはスクロール）
        let filtered = QueryFilters.parse(q).isActive
        let total = filtered ? allLimit : SearchPanelController.maxRows
        let aj = e.searchJudged(q, limit: total)
        var appSec = ResultSection(title: "アプリ", symbol: "app.badge", items: aj.results.map { RowItem(.app($0)) })
        appSec.faded = aj.noMatch
        guard withFiles else {
            return Sections(sections: [appSec], notFound: aj.noMatch && !appSec.items.isEmpty, appsNoMatch: aj.noMatch, filesNoMatch: false)
        }
        let fj = e.searchFilesJudged(q, limit: total)
        var fileSec = ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: fj.results.map { RowItem(.file($0)) })
        fileSec.faded = fj.noMatch
        var fileFirst: Bool
        switch order {
        case .appsFirst: fileFirst = false
        case .filesFirst: fileFirst = true
        case .auto:
            let it = QueryIntent.parse(q)
            fileFirst = !it.isEmpty || it.hasRelation
            if aj.noMatch != fj.noMatch { fileFirst = aj.noMatch }
        }
        var first = fileFirst ? fileSec : appSec, second = fileFirst ? appSec : fileSec
        if filtered {
            let shown = [first, second].filter { !$0.items.isEmpty }
            let notFound = !shown.isEmpty && shown.allSatisfy(\.faded)
            return Sections(sections: [first, second], notFound: notFound, appsNoMatch: aj.noMatch, filesNoMatch: fj.noMatch)
        }
        let firstMax = 4
        let nSecond = min(second.items.count, total - min(first.items.count, firstMax))
        let nFirst = min(first.items.count, total - nSecond)
        first.items = Array(first.items.prefix(nFirst))
        second.items = Array(second.items.prefix(nSecond))
        let shown = [first, second].filter { !$0.items.isEmpty }
        let notFound = !shown.isEmpty && shown.allSatisfy(\.faded)
        return Sections(sections: [first, second], notFound: notFound, appsNoMatch: aj.noMatch, filesNoMatch: fj.noMatch)
    }

    private func open(_ q: String, _ c: Candidate, reveal: Bool) {
        finishSession(chosen: c)
        let ws = NSWorkspace.shared
        switch c {
        case .app(let r):
            if reveal {
                ws.selectFile(r.app.path, inFileViewerRootedAtPath: "")
            } else {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                ws.openApplication(at: URL(fileURLWithPath: r.app.path), configuration: cfg) { _, err in
                    if let err { rlogError("開けませんでした \(r.app.path) \(err)") }
                }
            }
            if settings.learn { learnWork.async { [weak self] in self?.engine?.learn(query: q, app: r.app) } }
        case .file(let r):
            let url = URL(fileURLWithPath: r.file.path)
            if reveal {
                ws.selectFile(r.file.path, inFileViewerRootedAtPath: "")
            } else if r.file.isDir, let finder = ws.urlForApplication(withBundleIdentifier: "com.apple.finder") {
                // フォルダは既定のアプリに関係なく Finder で開く
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                ws.open([url], withApplicationAt: finder, configuration: cfg) { _, err in
                    if let err { rlogError("開けませんでした \(err)") }
                }
            } else if let appURL = ws.urlForApplication(toOpen: url) {
                // 開くアプリを先に決めて開き、その組を覚える（file → app の opened_with の線）
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                ws.open([url], withApplicationAt: appURL, configuration: cfg) { [weak self] _, err in
                    if let err { rlogError("開けませんでした \(err)"); return }
                    self?.fileWork.async { self?.engine?.recordOpened(file: r.file.path, appURL: appURL) }
                }
            } else if !ws.open(url) {
                rlogError("開けませんでした \(r.file.path)")
            }
            if settings.learn { learnFile(q, r.file) }
        }
    }

    /// 入力欄を閉じたとき、検索の記録を 1 行残す（記録がオフ・何も打っていないときは残さない）
    private func finishSession(chosen: Candidate?) {
        guard let s = session else { return }
        session = nil
        guard settings.logSearches, !s.query.isEmpty, let store else { return }
        func info(_ c: Candidate) -> (String, String, String, Float) {
            switch c {
            case .app(let r): return ("app", r.app.key, r.app.jp, r.score)
            case .file(let r): return (r.file.isDir ? "folder" : "file", r.file.path, r.file.name, r.score)
            }
        }
        let cands = s.shown.map { c, sec -> SearchLogEntry.Candidate in
            let (k, key, name, score) = info(c)
            return .init(kind: k, key: key, name: name, score: score, section: sec)
        }
        var entry = SearchLogEntry(ts: Int(Date().timeIntervalSince1970), query: s.query, edits: s.edits, candidates: cands,
                                   dismissed: chosen == nil, notFound: s.notFound, notFoundApps: s.notFoundApps,
                                   notFoundFiles: s.notFoundFiles, ms: s.ms)
        if let c = chosen {
            let (k, key, name, _) = info(c)
            entry.chosenKind = k; entry.chosenKey = key; entry.chosenName = name
            entry.chosenRank = cands.firstIndex { $0.key == key && $0.kind == k }.map { $0 + 1 }
        }
        logWork.async { store.logSearch(entry) }
    }

    private func pruneSearchLog() {
        guard let store else { return }
        let days = settings.logDays
        logWork.async {
            let n = store.pruneSearchLog(days: days)
            if n > 0 { rlog("\(days) 日より古い検索の記録を \(n) 件消した") }
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

    /// 覚えた例を Store から読み直してメモリに入れる（消したとき）
    private func reloadExamples() {
        guard let e = engine else { return }
        learnWork.async { e.loadExamples() }
        fileWork.async {
            e.clearFileExamples()
            let exs = e.store?.fileExamples() ?? []
            if !exs.isEmpty { e.addFileExamples(exs) }
        }
    }

    // MARK: モデルの解放

    private func scheduleUnload() {
        unloadTimer?.invalidate()
        let m = settings.unloadMinutes
        guard m > 0 else { return }
        unloadTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(m * 60), repeats: false) { [weak self] _ in
            guard let self, !self.panel.isVisible else { return }
            self.work.async {
                self.bge?.unload()
                rlog(String(format: "モデルを解放 メモリ %.0fMB", physFootprintMB()))
            }
        }
    }

    // MARK: メニュー

    /// 窓の操作（⌘W・⌘,）と、文字の入力欄の ⌘C / ⌘V が効くように、アプリのメニューを持つ（メニューバーには出ない）
    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Raiden を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "編集")
        edit.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let winItem = NSMenuItem()
        let win = NSMenu(title: "ウインドウ")
        win.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Raiden")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Raiden を開く", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        let sub = NSMenu()
        for (m, title) in [(0, "解放しない"), (5, "閉じて 5 分後"), (30, "閉じて 30 分後")] {
            let it = NSMenuItem(title: title, action: #selector(setUnload(_:)), keyEquivalent: "")
            it.target = self
            it.tag = m
            it.state = m == settings.unloadMinutes ? .on : .off
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
        loginItem = login
        menu.addItem(.separator())
        menu.addItem(withTitle: "Raiden を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem?.state = LoginItem.isOn ? .on : .off
        unloadItems.forEach { $0.state = $0.tag == settings.unloadMinutes ? .on : .off }
    }

    @objc private func openPanel() { toggle() }
    @objc private func rescanNow() { rescan() }
    @objc private func toggleLogin(_ s: NSMenuItem) {
        setLogin(s.state != .on)
        s.state = LoginItem.isOn ? .on : .off
    }
    @objc private func setUnload(_ s: NSMenuItem) {
        updateSettings { $0.unloadMinutes = s.tag }
    }

    func applicationWillTerminate(_ notification: Notification) {
        rlog("終了")
        RaidenLog.shared.flush()
    }
}

// MARK: - 設定窓の口

extension AppDelegate: SettingsHost {
    var loginOn: Bool { LoginItem.isOn }

    func setLogin(_ on: Bool) {
        LoginItem.set(on)
        rlog("ログイン時に起動 \(on ? "オン" : "オフ")")
    }

    func learnedExamples() -> [LearnedExample] { store?.learnedExamples() ?? [] }

    func deleteLearned(_ e: LearnedExample) {
        store?.deleteLearned(query: e.query, kind: e.kind, key: e.key)
        reloadExamples()
    }

    func clearLearned() {
        store?.clearLearned()
        reloadExamples()
        rlog("覚えた例を全部消した")
    }

    static var appNotesURL: URL {
        if let p = ProcessInfo.processInfo.environment["RAIDEN_APP_NOTES"] { return URL(fileURLWithPath: p) }
        return RaidenPaths.support.appendingPathComponent("app-notes.json")
    }

    func appNotes() -> [(String, String)] {
        guard let d = try? Data(contentsOf: Self.appNotesURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return o.compactMap { k, v in (v as? String).map { (k, $0) } }.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    func saveAppNotes(_ notes: [(String, String)]) {
        var o: [String: String] = [:]
        for (k, v) in notes { o[k] = v }
        do {
            let d = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(at: Self.appNotesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: Self.appNotesURL, options: .atomic)
            rlog("app-notes.json を保存 \(o.count) 件")
            rescan()  // 説明文が変わったアプリだけベクトルを作り直す
        } catch {
            rlogError("app-notes.json を保存できませんでした \(error)")
        }
    }

    func recentSearches() -> [SearchLogEntry] { store?.searchLog(limit: 200) ?? [] }

    /// 見つからなかった言い方（同じ言い方は新しい 1 件だけ）
    func notFoundSearches() -> [SearchLogEntry] {
        var seen = Set<String>()
        return (store?.searchLog(limit: 500, onlyNotFound: true) ?? []).filter { seen.insert($0.query).inserted }
    }

    func searchLogCount() -> Int { store?.searchLogCount() ?? 0 }

    func clearSearchLog() {
        store?.clearSearchLog()
        rlog("検索の記録を全部消した")
    }

    var logFolderPath: String { RaidenSettings.tilde(RaidenLog.shared.dir.path) }

    func openLogFolder() {
        let dir = RaidenLog.shared.dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// 見つからなかった言い方に、正解のアプリ・ファイル・フォルダを選んで教える（例として覚え、記録にも書き足す）
    func teach(_ e: SearchLogEntry, completion: @escaping (String?) -> Void) {
        guard let engine, let store else { completion("まだ準備中です"); return }
        let p = NSOpenPanel()
        p.title = "「\(e.query)」の正解を選ぶ"
        p.prompt = "これが正解"
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.treatsFilePackagesAsDirectories = false
        p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard p.runModal() == .OK, let url = p.url else { completion(nil); return }
        let path = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        if path.hasSuffix(".app") {
            let bid = Bundle(url: url)?.bundleIdentifier
            guard let app = engine.apps.first(where: { $0.path == path || (bid != nil && $0.bundleID == bid) }) else {
                completion("このアプリは Raiden のアプリ一覧に入っていません"); return
            }
            learnWork.async {
                engine.learn(query: e.query, app: app)
                store.markSearchLogTaught(id: e.id, kind: "app", key: app.key, name: app.jp)
                rlog("正解を教えた「\(e.query)」→ \(app.jp)")
                completion(nil)
            }
            return
        }
        guard let idx = fileIndex else { completion("まだ準備中です"); return }
        fileWork.async {
            guard let f = idx.entries[path] else { completion("検索範囲の外にあるファイルです。先に「検索範囲」に入れてください"); return }
            let q = e.query.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            let v = engine.embedder.embed(q)
            store.recordFileChoice(query: q, path: f.path, isDir: f.isDir, name: f.name, vector: v, model: engine.embedder.identifier)
            engine.addFileExamples([(q, f.path)])
            store.markSearchLogTaught(id: e.id, kind: f.isDir ? "folder" : "file", key: f.path, name: f.name)
            rlog("正解を教えた「\(q)」→ \(f.name)")
            completion(nil)
        }
    }
}

// Raiden --snapshot <dir>: 入力欄と設定窓の見本を PNG に書き出して終わる（画面には出さない）
if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "docs/ui"
    Snapshot.run(dir: dir)
    exit(0)
}

// Raiden --test-focus: 入力欄が一覧を選んだ後も打てるかを確かめて終わる（画面には出さない。失敗なら exit 1）
if CommandLine.arguments.contains("--test-focus") {
    _ = NSApplication.shared
    exit(FocusTest.run() ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
