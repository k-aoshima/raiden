import AppKit
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

        shoot(dir + "/panel-normal.png", query: "PDFを見るやつ", sections: [appSec, fileSec])
        shoot(dir + "/panel-selected.png", query: "PDFを見るやつ", sections: [appSec, fileSec], select: 6)
        var weakApps = appSec, weakFiles = fileSec
        weakApps.items = Array(apps.prefix(2)); weakFiles.items = Array(files.prefix(2))
        shoot(dir + "/panel-notfound.png", query: "ふわふわのやつ", sections: [weakApps, weakFiles], notFound: true)
        shoot(dir + "/panel-preparing.png", query: "PDFを見るやつ", sections: [appSec],
              status: ("ファイル準備中… 300", "hourglass"))
        FilterSnapshots.run(dir: dir)
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

        // 明るい壁紙の代わりの背景に載せる（ガラスのぼかしは画面外では描かれないため、白い面だけが写る）
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
        let img = NSImage(size: b.size)
        img.addRepresentation(shot)
        img.draw(in: NSRect(x: pad, y: pad, width: b.width, height: b.height))
        NSGraphicsContext.restoreGraphicsState()
        if let png = out.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("書き出し \(path)  \(Int(b.width))×\(Int(b.height))")
        }
    }
}
