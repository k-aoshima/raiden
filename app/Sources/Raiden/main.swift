import AppKit
import Carbon
import RaidenCore

/// メニューバー常駐。ホットキーで入力欄を出し、アプリ（名前・辞書・選んだ記録の文字の一致）とファイル・フォルダ（Spotlight）を探して開く。
/// 選んで開いた組は raiden.sqlite に記録として残り、次から入力の文字が近ければ効く。埋め込みモデルは使わない。
/// 設定は ~/Library/Application Support/Raiden/settings.json（設定の窓で変える）。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let panel = SearchPanelController()
    private var hotKey: HotKey?
    /// クリップボードの履歴を開くキー
    private var clipHotKey: HotKey?
    private(set) var clipHotKeyLabel = ""
    private var clipWatcher: ClipboardWatcher?
    private(set) var hotKeyLabel = ""
    private var engine: Engine?
    /// 値の候補の件数と最近使った物（Spotlight で裏で数える）
    private var filterSource: SpotlightFilterSource?
    private var store: Store?
    private let work = DispatchQueue(label: "raiden.work", qos: .userInitiated)
    /// 選んだ記録・開いた記録の保存（検索の列を止めないように分ける）
    private let learnWork = DispatchQueue(label: "raiden.learn", qos: .utility)
    /// 検索の記録の書き込み
    private let logWork = DispatchQueue(label: "raiden.searchlog", qos: .utility)
    private var generation = 0
    private var pendingQuery: DispatchWorkItem?
    /// 入力が止まってから検索するまでの待ち
    private static let debounce: TimeInterval = 0.1
    private var appWatcher: FSWatcher?
    /// 1 日 1 回、アプリ一覧を取り直す（ふだんはアプリの場所の FSEvents で拾う）
    private static let rescanInterval: TimeInterval = 86400
    private var loginItem: NSMenuItem?

    private(set) var settings = RaidenSettings()
    private var settingsWindow: SettingsWindowController?
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
        panel.recentSections = { [weak self] in
            guard let fs = self?.filterSource else { return [] }
            return Recall.sessions(fs.recentEntries(limit: 40)).map { ss in
                ResultSection(title: ss.title, symbol: "clock", items: ss.items.map { RowItem(.file(FileResult(file: $0, score: 0))) })
            }
        }
        panel.onHide = { [weak self] in
            self?.engine?.cancelFiles()
            // 選んで閉じたときは open が先に記録する。残っていれば選ばずに閉じた
            DispatchQueue.main.async { self?.finishSession(chosen: nil) }
        }
        // 値の候補の件数と最近使った物は Spotlight で裏で数える（SpotlightFilterSource。届いたら一覧を出し直す）
        panel.filterInput.context = { [weak self] in self?.filterSource }
        panel.filterInput.clips = { [weak self] in self?.store?.allClips() ?? [] }
        setupFilterHooks()
        panel.setStatus("準備中…", symbol: "hourglass")
        work.async { [weak self] in self?.boot() }
        // 取りこぼしの保険（1 日 1 回、アプリ一覧を取り直す）と、古い検索の記録の掃除
        Timer.scheduledTimer(withTimeInterval: Self.rescanInterval, repeats: true) { [weak self] _ in
            self?.rescan()
            self?.pruneSearchLog()
        }
    }

    // MARK: 設定

    private func loadSettings() {
        settings = RaidenSettings.load()
        PanelStyle.transparency = settings.transparency
        SearchPanelController.maxRows = settings.maxRows
        SearchPanelController.previewEnabled = settings.showPreview
        SavedFilters.set(settings.savedFilters)
        PhraseDictionary.set(settings.dictionary)
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
        if old.exclude != s.exclude {
            let ex = s.exclude
            work.async { [weak self] in self?.engine?.spotlight.exclude = ex; self?.filterSource?.search.exclude = ex }
        }
        if old.transparency != s.transparency { previewTransparency(s.transparency) }
        if old.maxRows != s.maxRows { SearchPanelController.maxRows = s.maxRows }
        if old.showPreview != s.showPreview { SearchPanelController.previewEnabled = s.showPreview }
        if old.savedFilters != s.savedFilters { SavedFilters.set(s.savedFilters) }
        if old.dictionary != s.dictionary { PhraseDictionary.set(s.dictionary) }
        if old.logDays != s.logDays { pruneSearchLog() }
        if old.clipboard != s.clipboard {
            if s.clipboard { clipWatcher?.start() } else { clipWatcher?.stop() }
            rlog("クリップボードの履歴を\(s.clipboard ? "オン" : "オフ")")
        }
        if old.excludeFolders != s.excludeFolders || old.excludeNames != s.excludeNames {
            rlog("除外を変更 フォルダ \(s.excludeFolders) 名前 \(s.excludeNames)")
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
            let store = try Store()
            if store.migratedFiles > 0 {
                rlog("前の版のファイル一覧とベクトルを消した（ファイル・フォルダの点 \(store.migratedFiles) 件）")
            }
            let ex = DispatchQueue.main.sync { settings.exclude }
            let e = Engine(store: store, exclude: ex)
            let opens = OpenWithIndex.build(exclude: ex)
            e.setApps(AppCatalog.collect(opens: opens))
            e.loadExamples()
            self.store = store
            engine = e
            // 検索の問い合わせ（打つたびに前を止める）と取り消し合わないよう、別の SpotlightSearch で数える
            let fs = SpotlightFilterSource(search: SpotlightSearch(exclude: ex))
            fs.appCountProvider = { [weak e] in e?.apps.count ?? 0 }
            fs.onUpdate = { [weak self] in DispatchQueue.main.async { self?.panel.filterInput.sourceDidUpdate(); self?.panel.showRecent() } }
            DispatchQueue.main.sync { self.filterSource = fs }
            rlog(String(format: "起動 %.2fs  アプリ %d  記録 %d  メモリ %.0fMB", Date().timeIntervalSince(t0), e.apps.count, e.examples.count, physFootprintMB()))
            DispatchQueue.main.async {
                self.panel.setStatus("")
                // アプリの場所はフォルダ単位で十分（.app の中の細かい変化はまとめて 1 回の取り直しになる）
                self.appWatcher = FSWatcher(paths: AppCatalog.dirs, fileEvents: false, quiet: 1.0, maxWait: 5.0) { [weak self] _ in
                    self?.rescan()
                }
                self.pruneSearchLog()
                self.clipWatcher = ClipboardWatcher(store: store) { [weak self] in self?.settings.clipKeep ?? 500 }
                if self.settings.clipboard { self.clipWatcher?.start() }
            }
        } catch {
            rlogError("起動に失敗 \(error)")
            DispatchQueue.main.async { self.panel.setStatus("データベースを開けませんでした", symbol: "exclamationmark.triangle") }
        }
    }

    private func rescan() {
        let ex = settings.exclude
        work.async { [weak self] in
            guard let e = self?.engine else { return }
            let t = Date()
            let opens = OpenWithIndex.build(exclude: ex)
            e.setApps(AppCatalog.collect(opens: opens))
            rlog(String(format: "アプリ一覧を作り直し %d 個 %.1fs", e.apps.count, Date().timeIntervalSince(t)))
        }
    }

    // MARK: ホットキー

    private func setupHotKey() {
        registerHotKey()
        registerClipHotKey()
        rlog("ホットキー \(hotKeyLabel)  クリップボード \(clipHotKeyLabel)")
    }

    /// クリップボードの履歴を開くキー。設定が無ければ ⌥V、取れなければ ⌃⌥V
    @discardableResult
    private func registerClipHotKey() -> Bool {
        clipHotKey = nil
        let candidates = settings.clipHotKey.map { [$0] } ?? [HotKeyInfo.clipDefaultKey, HotKeyInfo.clipFallbackKey]
        for c in candidates {
            if let hk = HotKey(keyCode: c.keyCode, modifiers: c.modifiers, action: { [weak self] in self?.toggleClipboard() }) {
                clipHotKey = hk
                clipHotKeyLabel = c.label
                return true
            }
        }
        if settings.clipHotKey != nil {
            rlogError("クリップボードのキー \(settings.clipHotKey!.label) を登録できなかったので初期値に戻す")
            settings.clipHotKey = nil
            return registerClipHotKey()
        }
        clipHotKeyLabel = ""
        return false
    }

    func applyClipHotKey(_ hk: RaidenSettings.HotKeySetting?) -> String? {
        let before = settings.clipHotKey
        updateSettings { $0.clipHotKey = hk }
        if registerClipHotKey() && (hk == nil || clipHotKeyLabel == hk!.label) {
            rlog("クリップボードのキーを変更 \(clipHotKeyLabel)")
            return nil
        }
        updateSettings { $0.clipHotKey = before }
        registerClipHotKey()
        return "\(hk?.label ?? "") はほかのアプリが使っていて登録できませんでした。別のキーにしてください"
    }

    /// クリップボードの履歴の状態で入力欄を出す。履歴を出している時にもう一度押したら閉じる
    private func toggleClipboard() {
        if panel.isVisible && panel.filterInput.clipMode { panel.hide(); return }
        let wasVisible = panel.isVisible
        clipWatcher?.startKeyMonitor()
        panel.showClipboard()
        if !wasVisible { session = Session() }
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
        if on { hotKey = nil; clipHotKey = nil } else {
            if hotKey == nil { registerHotKey() }
            if clipHotKey == nil { registerClipHotKey() }
        }
    }

    private func toggle() {
        if panel.isVisible { panel.hide(); return }
        panel.show()
        session = Session()
        clipWatcher?.startKeyMonitor()
        filterSource?.refreshRecent()
    }

    // MARK: 検索と開く

    /// 入力のたびに呼ばれる。入力が止まって debounce 秒たってから検索し、古い問い合わせは捨てる（走っている Spotlight も止める）
    private func query(_ q: String) {
        generation += 1
        let g = generation
        pendingQuery?.cancel()
        pendingQuery = nil
        engine?.cancelFiles()
        if var s = session, s.edits.last?.q != q {
            if s.edits.count < 100 { s.edits.append(.init(q: q, t: Int(Date().timeIntervalSince(s.opened) * 1000))) }
            s.query = q
            if q.isEmpty { s.shown = []; s.notFound = false; s.notFoundApps = false; s.notFoundFiles = false }
            session = s
        }
        if q.isEmpty { panel.showRecent(); return }
        if let words = QueryFilters.clipText(q) { queryClips(words, q: q, generation: g); return }
        let order = settings.sectionOrder
        let item = DispatchWorkItem { [weak self] in
            self?.work.async {
                guard let self, let e = self.engine else { return }
                // 待っている間に次の文字が来ていたら捨てる
                var stale = false
                DispatchQueue.main.sync { stale = g != self.generation }
                if stale { return }
                let t0 = Date()
                let r = Self.sections(q, engine: e, order: order)
                let ms = Date().timeIntervalSince(t0) * 1000
                DispatchQueue.main.async {
                    guard g == self.generation else { return }
                    self.panel.setResults(r.sections, query: q, notFound: r.notFound, split: r.split)
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

    /// クリップボードの履歴（新しい順。言葉があれば文字とコピー元のアプリの名前で絞る）
    private func queryClips(_ words: String, q: String, generation g: Int) {
        guard let store else { return }
        let on = settings.clipboard
        work.async { [weak self] in
            let items = store.clips(matching: words)
            DispatchQueue.main.async {
                guard let self, g == self.generation else { return }
                var sec = ResultSection(title: "クリップボード", symbol: "doc.on.clipboard", items: items.map { RowItem(.clip($0)) })
                if items.isEmpty {
                    sec.items = [RowItem(title: on ? (words.isEmpty ? "まだ履歴がありません" : "見つかりません") : "クリップボードの履歴はオフです",
                                         sub: on ? "文字をコピーするとここに出ます" : "設定 → 一般 でオンにできます",
                                         iconImage: NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil), hint: "")]
                }
                self.panel.setResults([sec], query: q)
            }
        }
    }

    struct Sections {
        var sections: [ResultSection]
        var notFound: Bool
        var appsNoMatch: Bool
        var filesNoMatch: Bool
        var split: RecallSplit? = nil
    }

    /// アプリとファイルを節に分けて並べる（合計 maxRows 件）。
    /// 点数はアプリとファイルで付け方が違う（アプリは名前・辞書・記録、ファイルは名前・新しさ・記録）ので混ぜない。
    /// 並び（設定の「一般」）が自動なら、ふだんはアプリの節が先。時間・種類・つながりの言葉（「先週のPDF」「〜のとこ」）があればファイルの節を先にする。
    /// 先の節は最大 4 件、残りを後の節に回す（後の節が少なければ先の節に戻す）。
    /// 「見つからない」は Engine の印（searchJudged / searchFilesJudged）を節ごとに見る。
    /// 印の立った節は候補を薄くし、見出しに「見つかりません」を添える。
    /// 自動のとき、片方の節だけ印が立ったら当たった節を先にする（「先週のPDF」でアプリが見つからないのは普通なので、全体は「見つかりません」にしない）。
    /// 出している節が全部見つからないときだけ notFound を true にする（パネルは上に「見つかりません」を大きく出す）。
    /// 絞り込みで全部出すときの上限（実質なし）
    static let allLimit = 100_000

    static func sections(_ q: String, engine e: Engine, withFiles: Bool = true, order: SectionOrder = .auto) -> Sections {
        // 絞り込みのコマンド（#type #kind #ext #date #path #name）が効いているときは上限で切らず全部出す（パネルはスクロール）
        let filtered = QueryFilters.parse(q).isActive
        let total = filtered ? allLimit : SearchPanelController.maxRows
        let aj = e.searchJudged(q, limit: total)
        var appSec = ResultSection(title: "アプリ", symbol: "app.badge", items: aj.results.map { RowItem(.app($0)) })
        appSec.faded = aj.noMatch
        guard withFiles else {
            return Sections(sections: [appSec], notFound: aj.noMatch && !appSec.items.isEmpty, appsNoMatch: aj.noMatch, filesNoMatch: false)
        }
        let fj0 = e.searchFilesJudged(q, limit: total)
        let fileResults = fj0.results
        let filesNoMatch = fj0.noMatch
        var fileSec = ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: fileResults.map { RowItem(.file($0)) })
        fileSec.faded = filesNoMatch
        var fileFirst: Bool
        switch order {
        case .appsFirst: fileFirst = false
        case .filesFirst: fileFirst = true
        case .auto:
            let it = QueryIntent.parse(q)
            fileFirst = !it.isEmpty || it.hasRelation
            if aj.noMatch != filesNoMatch { fileFirst = aj.noMatch }
        }
        var first = fileFirst ? fileSec : appSec, second = fileFirst ? appSec : fileSec
        if filtered {
            let shown = [first, second].filter { !$0.items.isEmpty }
            let notFound = !shown.isEmpty && shown.allSatisfy(\.faded)
            // 絞り込みで長い一覧になるときは、ファイルを時期の棚（今日・昨日・今週…）に分けて新しい順に並べる
            var secs = [first, second]
            if fileSec.items.count > SearchPanelController.maxRows, let i = secs.firstIndex(where: { $0.symbol == "folder" }) {
                secs.replaceSubrange(i...i, with: timeShelves(fileSec))
            }
            // 何も見つからなければ「探し方を変える」の案（時期を広げる・本文から・条件を 1 つ外す）
            let none = fileSec.items.isEmpty && appSec.items.isEmpty
            return Sections(sections: secs, notFound: notFound, appsNoMatch: aj.noMatch, filesNoMatch: filesNoMatch,
                            split: none ? e.alternatives(q) : fj0.split)
        }
        let firstMax = 4
        let nSecond = min(second.items.count, total - min(first.items.count, firstMax))
        let nFirst = min(first.items.count, total - nSecond)
        first.items = Array(first.items.prefix(nFirst))
        second.items = Array(second.items.prefix(nSecond))
        let shown = [first, second].filter { !$0.items.isEmpty }
        let notFound = !shown.isEmpty && shown.allSatisfy(\.faded)
        // アプリもファイルも見つからなければ「本文から探す」などの案（アプリが当たる入力では数えない。打つたびに遅くしないため）
        let alt = fileResults.isEmpty && aj.noMatch ? e.alternatives(q) : nil
        return Sections(sections: [first, second], notFound: notFound, appsNoMatch: aj.noMatch, filesNoMatch: filesNoMatch,
                        split: alt ?? (notFound ? nil : fj0.split))
    }

    /// ファイルの節を時期の棚に分ける。棚は新しい順、棚の中は元の並び（点数の順）。
    /// 時期は最後に触った日（使った日・変更日・追加日・作成日の一番新しい日。#date と同じ）
    static func timeShelves(_ sec: ResultSection, now: Date = Date()) -> [ResultSection] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let week = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let lastWeek = cal.date(byAdding: .day, value: -7, to: week) ?? week
        let month = cal.dateInterval(of: .month, for: now)?.start ?? today
        let year = cal.dateInterval(of: .year, for: now)?.start ?? today
        func shelf(_ e: FileEntry) -> (Int, String) {
            let t = max(e.lastUsed, e.mtime, e.added, e.created)
            guard t > 0 else { return (Int.min, "日付なし") }
            let d = Date(timeIntervalSince1970: TimeInterval(t))
            if d >= today { return (0, "今日") }
            if d >= cal.date(byAdding: .day, value: -1, to: today)! { return (1, "昨日") }
            if d >= week { return (2, "今週") }
            if d >= lastWeek { return (3, "先週") }
            if d >= month { return (4, "今月") }
            let c = cal.dateComponents([.year, .month], from: d)
            // 今年は月ごと、それより前は年ごと（並びの鍵は新しいほど小さく）
            if d >= year { return (100 - c.month!, "\(c.month!)月") }
            return (10_000 - c.year!, "\(c.year!)年")
        }
        var order: [(Int, String)] = []
        var groups: [String: [RowItem]] = [:]
        for it in sec.items {
            guard case .file(let r)? = it.candidate else { continue }
            let s = shelf(r.file)
            if groups[s.1] == nil { order.append(s) }
            groups[s.1, default: []].append(it)
        }
        if order.count <= 1 { return [sec] }
        return order.sorted { $0.0 == $1.0 ? false : ($0.0 == Int.min ? false : ($1.0 == Int.min ? true : $0.0 < $1.0)) }.map { s in
            var x = ResultSection(title: s.1, symbol: "clock", items: groups[s.1] ?? [])
            x.faded = sec.faded
            return x
        }
    }

    private func open(_ q: String, _ c: Candidate, reveal: Bool) {
        finishSession(chosen: c)
        let ws = NSWorkspace.shared
        switch c {
        case .clip(let item):
            // ↩ は前のアプリに戻して貼る、⌘↩ はコピーだけ
            clipWatcher?.use(item, paste: !reveal, target: panel.previousApp)
        case .app(let r):
            if reveal {
                ws.selectFile(r.app.path, inFileViewerRootedAtPath: "")
            } else if r.app.bundleID == Bundle.main.bundleIdentifier {
                // Raiden 自身を選んだら設定窓を開く（常駐していて開く窓が無いため）
                DispatchQueue.main.async { [weak self] in self?.openSettings() }
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
                ws.open([url], withApplicationAt: finder, configuration: cfg) { [weak self] _, err in
                    if let err { rlogError("開けませんでした \(err)"); return }
                    self?.learnWork.async { self?.engine?.recordOpened(file: r.file.path, isDir: true, appURL: nil) }
                }
            } else if let appURL = ws.urlForApplication(toOpen: url) {
                // 開くアプリを先に決めて開き、その組を覚える（file → app の opened_with の線）
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                ws.open([url], withApplicationAt: appURL, configuration: cfg) { [weak self] _, err in
                    if let err { rlogError("開けませんでした \(err)"); return }
                    self?.learnWork.async { self?.engine?.recordOpened(file: r.file.path, appURL: appURL) }
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
        // クリップボードの履歴は中身が残るので検索の記録に書かない
        guard settings.logSearches, !s.query.isEmpty, QueryFilters.clipText(s.query) == nil, let store else { return }
        func info(_ c: Candidate) -> (String, String, String, Float) {
            switch c {
            case .app(let r): return ("app", r.app.key, r.app.jp, r.score)
            case .file(let r): return (r.file.isDir ? "folder" : "file", r.file.path, r.file.name, r.score)
            case .clip(let c): return ("clip", String(c.id), "", 0)
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
        refreshFilterMemory()
    }

    // MARK: 「#」の覚えた使い方・保存した名前・辞書（FilterMemory.swift, PhraseDictionary.swift, FilterUI.swift）

    /// 検索の記録から覚えた「#」の使い方（よく使う組み合わせ・値・場所・選ばずに閉じた言い方）。記録を書くたびに読み直す
    private(set) var filterMemory = FilterMemory.empty

    private func setupFilterHooks() {
        panel.filterInput.memory = { [weak self] in self?.filterMemory ?? .empty }
        panel.filterInput.onSave = { [weak self] sf in
            guard let self else { return false }
            let over = self.settings.savedFilters.contains { Describe.normalize($0.name) == Describe.normalize(sf.name) }
            self.updateSettings { s in
                s.savedFilters.removeAll { Describe.normalize($0.name) == Describe.normalize(sf.name) }
                s.savedFilters.append(sf)
            }
            rlog("絞り込みを保存 #\(sf.name) = \(sf.text)")
            return over
        }
        panel.filterInput.onAddDictionary = { [weak self] e in self?.addDictionary(e) ?? false }
        panel.dictionaryCandidates = { [weak self] q in DictionaryLookup.candidates(q, apps: self?.engine?.apps ?? []) }
    }

    /// 辞書に足す（同じ言い方は置き換える）。置き換えたら true
    @discardableResult
    func addDictionary(_ e: DictEntry) -> Bool {
        let r = PhraseDictionary.adding(e, to: settings.dictionary)
        updateSettings { $0.dictionary = r.list }
        rlog("辞書に\(r.replaced ? "置き換え" : "追加")「\(e.phrase)」→ \(e.name)")
        return r.replaced
    }

    private func refreshFilterMemory() {
        guard let store else { return }
        logWork.async { [weak self] in
            let m = FilterMemory.build(from: store.searchLog(limit: 3000))
            DispatchQueue.main.async { self?.filterMemory = m }
        }
    }

    func filterCombos() -> [FilterMemory.Combo] { filterMemory.combos }

    func appChoices() -> [(String, String)] {
        (engine?.apps ?? []).map { ($0.jp, $0.path) }.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    private func pruneSearchLog() {
        guard let store else { return }
        let days = settings.logDays
        logWork.async {
            let n = store.pruneSearchLog(days: days)
            if n > 0 { rlog("\(days) 日より古い検索の記録を \(n) 件消した") }
        }
    }

    /// 「入力 → ファイル」を選んだ記録として残す（次から、入力の文字が近ければ加点する）
    private func learnFile(_ query: String, _ f: FileEntry) {
        guard let e = engine else { return }
        learnWork.async { e.learnFile(query: query, file: f) }
    }

    /// 覚えた記録を Store から読み直してメモリに入れる（消したとき）
    private func reloadExamples() {
        guard let e = engine else { return }
        learnWork.async { e.loadExamples() }
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
    }

    @objc private func openPanel() { toggle() }
    @objc private func rescanNow() { rescan() }
    @objc private func toggleLogin(_ s: NSMenuItem) {
        setLogin(s.state != .on)
        s.state = LoginItem.isOn ? .on : .off
    }

    func applicationWillTerminate(_ notification: Notification) {
        rlog("終了")
        RaidenLog.shared.flush()
    }
}

// MARK: - 設定窓の口

extension AppDelegate: SettingsHost {
    func clipCount() -> Int { store?.clipCount() ?? 0 }
    func clearClips() { store?.clearClips(); rlog("クリップボードの履歴を全部消した") }

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
        learnWork.async {
            var dir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &dir)
            let f = SpotlightSearch.entry(path: path) ?? FileEntry(path: path, isDir: dir.boolValue)
            let q = e.query.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            engine.learnFile(query: q, file: f)
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
