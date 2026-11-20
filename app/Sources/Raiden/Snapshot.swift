import AppKit
import RaidenCore
import UniformTypeIdentifiers

/// 入力欄の見本を PNG に書き出す（Raiden --snapshot <dir>）。画面には出さず、画面外のパネルの中身を撮る。
/// OS がダークモードでも白く出ることを見るため、アプリ全体はダーク（darkAqua）にして撮る。
/// 候補はダミー（私的なファイル名は使わない）。アプリのアイコンだけ OS 付属のアプリから借りる。
enum Snapshot {
    static func run(dir: String) {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        func fileIcon(_ t: UTType) -> NSImage { NSWorkspace.shared.icon(for: t) }
        let apps = [
            RowItem(title: "プレビュー  Preview", sub: "/System/Applications/Preview.app",
                    iconPath: "/System/Applications/Preview.app", hint: RowItem.appHint),
            RowItem(title: "ブック  Books", sub: "/System/Applications/Books.app",
                    iconPath: "/System/Applications/Books.app", hint: RowItem.appHint),
            RowItem(title: "テキストエディット  TextEdit", sub: "/System/Applications/TextEdit.app",
                    iconPath: "/System/Applications/TextEdit.app", hint: RowItem.appHint),
        ]
        let files = [
            RowItem(title: "見積書_サンプル.pdf", sub: "~/Documents/サンプル", iconImage: fileIcon(.pdf), hint: RowItem.fileHint),
            RowItem(title: "議事録_サンプル.md", sub: "~/Documents/サンプル/メモ",
                    iconImage: fileIcon(UTType("net.daringfireball.markdown") ?? .plainText), hint: RowItem.fileHint),
            RowItem(title: "スクリーンショット サンプル.png", sub: "~/Desktop", iconImage: fileIcon(.png), hint: RowItem.fileHint),
            RowItem(title: "サンプル資料", sub: "~/Documents", iconImage: fileIcon(.folder), hint: RowItem.folderHint),
        ]
        let appSec = ResultSection(title: "アプリ", symbol: "app.badge", items: apps)
        let fileSec = ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: files)

        shoot(dir + "/panel-empty.png", query: "", sections: [])
        shoot(dir + "/panel-normal.png", query: "PDFを見るやつ", sections: [appSec, fileSec])
        shoot(dir + "/panel-selected.png", query: "PDFを見るやつ", sections: [appSec, fileSec], select: 6)
        var weakApps = appSec, weakFiles = fileSec
        weakApps.items = Array(apps.prefix(2)); weakFiles.items = Array(files.prefix(2))
        shoot(dir + "/panel-notfound.png", query: "ふわふわのやつ", sections: [weakApps, weakFiles], notFound: true)
        shootPreview(dir + "/panel-preview.png", apps: apps)
        shootSettings(dir: dir)
        FilterSnapshots.run(dir: dir)
    }

    /// プレビューを出した状態（panel-preview.png）。中身はこの場で作った見本のファイル（一時フォルダ）だけ
    static func shootPreview(_ path: String, apps: [RowItem]) {
        let root = "/tmp/raiden-preview-sample"
        try? FileManager.default.removeItem(atPath: root)
        let docs = (root as NSString).appendingPathComponent("サンプル資料")
        try? FileManager.default.createDirectory(atPath: docs, withIntermediateDirectories: true)
        let pdf = (root as NSString).appendingPathComponent("見積書_サンプル.pdf")
        writeSamplePDF(pdf)
        let md = (root as NSString).appendingPathComponent("議事録_サンプル.md")
        try? "# 議事録（見本）\n\n- 次回の日程を決める\n- 見積書を送る\n".write(toFile: md, atomically: true, encoding: .utf8)
        for n in ["企画書_見本.pdf", "写真_見本.png", "メモ_見本.txt"] {
            FileManager.default.createFile(atPath: (docs as NSString).appendingPathComponent(n), contents: Data("見本".utf8))
        }
        func row(_ p: String, folder: Bool = false) -> RowItem {
            RowItem(title: (p as NSString).lastPathComponent, sub: "~/Documents/サンプル",
                    iconImage: NSWorkspace.shared.icon(forFile: p), hint: folder ? RowItem.folderHint : RowItem.fileHint,
                    preview: .file(p))
        }
        let files = [row(pdf), row(md), row(docs, folder: true)]
        let secs = [ResultSection(title: "アプリ", symbol: "app.badge", items: Array(apps.prefix(2))),
                    ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: files)]
        let c = SearchPanelController()
        c.setQueryText("見積書")
        c.setResults(secs, query: "見積書")
        c.select(2)
        c.panel.contentView?.layoutSubtreeIfNeeded()
        c.preview.waitUntilLoaded()
        capture(c, path)
        try? FileManager.default.removeItem(atPath: root)
    }

    /// 見本の PDF（A4 の 1 枚に見積書らしい文字を並べる）
    static func writeSamplePDF(_ path: String) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil) else { return }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, bold: Bool = false) {
            (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular), .foregroundColor: NSColor.black])
        }
        text("御見積書（見本）", 60, 760, 28, bold: true)
        text("見本株式会社 御中", 60, 710, 14)
        text("合計金額  ¥123,000（税込）", 60, 660, 18, bold: true)
        NSColor(white: 0.85, alpha: 1).setFill()
        NSRect(x: 60, y: 600, width: 475, height: 24).fill()
        text("品目", 70, 605, 12, bold: true); text("数量", 360, 605, 12, bold: true); text("金額", 460, 605, 12, bold: true)
        for (i, r) in [("デザイン作業（見本）", "1", "¥80,000"), ("撮影（見本）", "2", "¥30,000"), ("交通費（見本）", "1", "¥13,000")].enumerated() {
            let y = 570 - CGFloat(i) * 30
            text(r.0, 70, y, 12); text(r.1, 365, y, 12); text(r.2, 460, y, 12)
            NSColor(white: 0.9, alpha: 1).setFill()
            NSRect(x: 60, y: y - 8, width: 475, height: 1).fill()
        }
        text("この書類は Raiden の画面の見本です。", 60, 120, 11)
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// 設定窓の各画面（settings-scope / general / learning / log.png）。中身はダミーと初期値だけ
    static func shootSettings(dir: String) {
        let host = DummySettingsHost()
        let c = SettingsWindowController(host: host)
        for t in SettingsWindowController.Tab.allCases {
            c.window.setContentSize(NSSize(width: SettingsStyle.width, height: SettingsStyle.height))
            c.select(t)
            // 中身が長い画面は窓を伸ばして全部写す
            c.window.setContentSize(NSSize(width: SettingsStyle.width, height: max(SettingsStyle.height, min(1100, c.contentHeight()))))
            guard let v = c.snapshotContent() else { continue }
            v.layoutSubtreeIfNeeded()
            let b = v.bounds
            var shot: NSBitmapImageRep?
            SettingsStyle.appearance.performAsCurrentDrawingAppearance {
                guard let rep = v.bitmapImageRepForCachingDisplay(in: b) else { return }
                v.cacheDisplay(in: b, to: rep)
                shot = rep
            }
            guard let shot else { print("撮れませんでした: \(t.file)"); continue }
            compose(shot, size: b.size, radius: 12, path: dir + "/settings-\(t.file).png")
        }
    }

    static func shoot(_ path: String, query: String, sections: [ResultSection], select: Int = 0,
                      notFound: Bool = false, status: (String, String)? = nil) {
        let c = SearchPanelController()
        c.setQueryText(query)
        if let (s, sym) = status { c.setStatus(s, symbol: sym) }
        c.setResults(sections, query: query, notFound: notFound)
        c.select(select)
        capture(c, path)
    }

    static func capture(_ c: SearchPanelController, _ path: String) {
        c.panel.contentView?.layoutSubtreeIfNeeded()
        c.filterInput.updateGhost()   // ゴーストテキストは入力欄の位置が決まってから置く
        let v = c.content
        v.layoutSubtreeIfNeeded()
        let b = v.bounds
        var shot: NSBitmapImageRep?
        PanelStyle.appearance.performAsCurrentDrawingAppearance {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: b) else { return }
            v.cacheDisplay(in: b, to: rep)
            shot = rep
        }
        guard let shot else { print("撮れませんでした: \(path)"); return }

        compose(shot, size: b.size, radius: 0, path: path)
    }

    /// 明るい壁紙の代わりの背景に載せて書き出す（ガラスのぼかしは画面外では描かれないため、白い面だけが写る）
    static func compose(_ shot: NSBitmapImageRep, size b: NSSize, radius: CGFloat, path: String) {
        let pad: CGFloat = 48, scale: CGFloat = 2
        let size = NSSize(width: b.width + pad * 2, height: b.height + pad * 2)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGradient(starting: NSColor(srgbRed: 0.80, green: 0.86, blue: 0.94, alpha: 1),
                   ending: NSColor(srgbRed: 0.93, green: 0.90, blue: 0.95, alpha: 1))?.draw(in: NSRect(origin: .zero, size: size), angle: -60)
        let sh = NSShadow()
        sh.shadowColor = NSColor(white: 0, alpha: 0.18)
        sh.shadowBlurRadius = 24
        sh.shadowOffset = NSSize(width: 0, height: -6)
        sh.set()
        let img = NSImage(size: b)
        img.addRepresentation(shot)
        let r = NSRect(x: pad, y: pad, width: b.width, height: b.height)
        if radius > 0 {
            // 窓の形（角の丸い面）。中身は透ける白なので、下に薄い面を敷いて影を付ける
            NSColor(white: 1, alpha: 0.35).setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            NSShadow().set()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
        }
        img.draw(in: r)
        NSGraphicsContext.restoreGraphicsState()
        if let png = out.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("書き出し \(path)  \(Int(b.width))×\(Int(b.height))")
        }
    }
}

/// 設定窓の見本用の口（私的なものは写さない。除外は初期値、例と記録はダミー）
final class DummySettingsHost: SettingsHost {
    var settings = RaidenSettings()
    func updateSettings(_ f: (inout RaidenSettings) -> Void) { f(&settings) }
    var hotKeyLabel: String { "⌥Space" }
    func applyHotKey(_ hk: RaidenSettings.HotKeySetting?) -> String? { nil }
    func suspendHotKey(_ on: Bool) {}
    var loginOn: Bool { true }
    func setLogin(_ on: Bool) {}
    let now = Int(Date().timeIntervalSince1970)
    func learnedExamples() -> [LearnedExample] {
        [LearnedExample(query: "PDFを見るやつ", kind: "app", key: "com.apple.Preview", name: "プレビュー", count: 5, lastUsed: now - 3600),
         LearnedExample(query: "黒い画面でコマンド", kind: "app", key: "com.apple.Terminal", name: "ターミナル", count: 3, lastUsed: now - 86400),
         LearnedExample(query: "先週の見積書", kind: "file", key: "/dummy/見積書_サンプル.pdf", name: "見積書_サンプル.pdf", count: 2, lastUsed: now - 86400 * 2),
         LearnedExample(query: "スクショ置き場", kind: "folder", key: "/dummy/スクリーンショット", name: "スクリーンショット", count: 1, lastUsed: now - 86400 * 5)]
    }
    func deleteLearned(_ e: LearnedExample) {}
    func clearLearned() {}
    func appNotes() -> [(String, String)] { [("com.example.sample", "声で文字を入力するアプリ（見本）")] }
    func saveAppNotes(_ notes: [(String, String)]) {}
    func recentSearches() -> [SearchLogEntry] {
        [SearchLogEntry(ts: now - 120, query: "PDFを見るやつ", edits: [], candidates: [], chosenKind: "app", chosenKey: "com.apple.Preview",
                        chosenName: "プレビュー", chosenRank: 1, dismissed: false, notFound: false, ms: 21),
         SearchLogEntry(ts: now - 900, query: "先週の見積書", edits: [], candidates: [], chosenKind: "file", chosenKey: "/dummy",
                        chosenName: "見積書_サンプル.pdf", chosenRank: 2, dismissed: false, notFound: false, ms: 24),
         SearchLogEntry(ts: now - 4000, query: "ふわふわのやつ", edits: [], candidates: [], dismissed: true, notFound: true, ms: 19)]
    }
    func notFoundSearches() -> [SearchLogEntry] { recentSearches().filter(\.notFound) }
    func searchLogCount() -> Int { 3 }
    func clearSearchLog() {}
    func openLogFolder() {}
    var logFolderPath: String { "~/Library/Logs/Raiden" }
    func teach(_ e: SearchLogEntry, completion: @escaping (String?) -> Void) { completion(nil) }
    func previewTransparency(_ t: Double) {}
}
