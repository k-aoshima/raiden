import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// 右のプレビューに出す物。ファイル・フォルダは中身、アプリは簡素に（アイコンと名前だけ）
enum PreviewTarget: Equatable {
    case file(String)
    case app(title: String, path: String)
}

/// 候補の右に出すプレビュー（Quick Look のサムネイル＋名前・種類・大きさ・変更日・場所）。
/// 行を素早く動かしたときは前の読み込みを取り消し、少し間を置いてから最後の物だけ読む。
/// 重い仕事（属性・フォルダの中身・サムネイル）は裏で行い、入力や矢印の反応を遅らせない。
final class FilePreviewPane: NSView {
    static let width: CGFloat = 380
    /// 行を動かしてから読み始めるまでの間（素早く動かしたときは最後の物だけ読む）
    static let delay: TimeInterval = 0.12

    private let box = NSView()
    private let image = NSImageView()
    private let children = NSStackView()
    private let name = NSTextField(wrappingLabelWithString: "")
    private let info = NSStackView()
    private var target: PreviewTarget?
    private var token = 0
    private var pending: DispatchWorkItem?
    private var request: QLThumbnailGenerator.Request?
    /// 読み終えた token（見本を撮るときに待つ）
    private(set) var loadedToken = -1
    var currentToken: Int { token }
    private static let work = DispatchQueue(label: "raiden.preview", qos: .userInitiated)

    override init(frame: NSRect) {
        super.init(frame: frame)
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.masksToBounds = true
        image.imageScaling = .scaleProportionallyUpOrDown
        image.imageAlignment = .alignCenter
        children.orientation = .vertical
        children.alignment = .leading
        children.spacing = 2
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.textColor = PanelStyle.text
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.truncatesLastVisibleLine = true
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 3
        for v in [box, name, info] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for v in [image, children] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
        }
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            box.bottomAnchor.constraint(equalTo: name.topAnchor, constant: -12),
            image.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            image.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
            image.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            image.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            children.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            children.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            children.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -12),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            info.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 8),
            info.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            info.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            info.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        image.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        image.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        name.setContentCompressionResistancePriority(.required, for: .vertical)
        info.setContentCompressionResistancePriority(.required, for: .vertical)
        name.setContentHuggingPriority(.required, for: .vertical)
        info.setHuggingPriority(.required, for: .vertical)
        info.setContentHuggingPriority(.required, for: .vertical)
        children.setHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 出す物を変える。icon は行のアイコン（読み終わるまでの仮の絵）
    func show(_ t: PreviewTarget?, title: String, icon: NSImage?) {
        guard t != target else { return }
        target = t
        token += 1
        pending?.cancel()
        if let r = request { QLThumbnailGenerator.shared.cancel(r); request = nil }
        children.arrangedSubviews.forEach { $0.removeFromSuperview() }
        children.isHidden = true
        image.isHidden = false
        guard let t else {
            image.image = nil; name.stringValue = ""; setInfo([]); loadedToken = token
            return
        }
        // すぐ出せる物（名前と行のアイコン）だけ先に出す
        image.image = icon
        name.stringValue = title
        box.layer?.backgroundColor = NSColor.clear.cgColor
        switch t {
        case .app(_, let path):
            setInfo([("種類", "アプリ"), ("場所", RowItem.shortParent(path))])
            loadedToken = token
        case .file(let path):
            setInfo([("場所", RowItem.shortParent(path))])
            let tk = token
            let item = DispatchWorkItem { [weak self] in self?.load(path: path, token: tk) }
            pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: item)
        }
    }

    /// 裏で属性・フォルダの中身を読み、Quick Look にサムネイルを頼む
    private func load(path: String, token tk: Int) {
        guard tk == token else { return }
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: max(120, box.bounds.width - 12), height: max(120, box.bounds.height - 12))
        Self.work.async { [weak self] in
            let meta = PreviewMeta(path: path)
            DispatchQueue.main.async {
                guard let self, tk == self.token else { return }
                self.apply(meta)
                if meta.isDir || !meta.exists {
                    self.loadedToken = tk
                    return
                }
                let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: size, scale: scale,
                                                       representationTypes: [.thumbnail, .icon])
                self.request = req
                QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
                    DispatchQueue.main.async {
                        guard let self, tk == self.token else { return }
                        self.request = nil
                        if let rep, rep.type == .thumbnail {
                            self.image.image = rep.nsImage
                            self.box.layer?.backgroundColor = NSColor(white: 1, alpha: 0.35).cgColor
                        }
                        self.loadedToken = tk
                    }
                }
            }
        }
    }

    private func apply(_ m: PreviewMeta) {
        var rows: [(String, String)] = [("種類", m.kind)]
        if let s = m.sizeText { rows.append((m.isDir ? "中身" : "大きさ", s)) }
        if let d = m.modified { rows.append(("変更日", Self.dateFormat.string(from: d))) }
        rows.append(("場所", RowItem.shortParent(m.path)))
        setInfo(rows)
        guard m.isDir, !m.children.isEmpty else { return }
        // フォルダは中身の先頭いくつか（アイコンは裏で読んだ物）
        image.isHidden = true
        children.isHidden = false
        box.layer?.backgroundColor = NSColor(white: 1, alpha: 0.35).cgColor
        let maxLines = max(3, Int((box.bounds.height - 20) / 22))
        for (i, c) in m.children.prefix(maxLines).enumerated() {
            if i == maxLines - 1 && m.childCount > maxLines {
                children.addArrangedSubview(Self.childLine(nil, "ほか \(m.childCount - i) 項目"))
                break
            }
            children.addArrangedSubview(Self.childLine(c.icon, c.name))
        }
    }

    private static func childLine(_ icon: NSImage?, _ text: String) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = icon == nil ? PanelStyle.faint : PanelStyle.text
        l.lineBreakMode = .byTruncatingMiddle
        let iv = NSImageView(image: icon ?? NSImage())
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let s = NSStackView(views: icon == nil ? [l] : [iv, l])
        s.orientation = .horizontal
        s.spacing = 6
        s.heightAnchor.constraint(equalToConstant: 20).isActive = true
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return s
    }

    private func setInfo(_ rows: [(String, String)]) {
        info.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (k, v) in rows {
            let kl = NSTextField(labelWithString: k)
            kl.font = .systemFont(ofSize: 11)
            kl.textColor = PanelStyle.faint
            kl.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let vl = NSTextField(labelWithString: v)
            vl.font = .systemFont(ofSize: 11)
            vl.textColor = PanelStyle.subText
            vl.lineBreakMode = .byTruncatingMiddle
            vl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let s = NSStackView(views: [kl, vl])
            s.orientation = .horizontal
            s.spacing = 8
            info.addArrangedSubview(s)
        }
    }

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/M/d H:mm"
        return f
    }()

    /// 見本を撮るとき用: 読み終わるまで待つ（最大 timeout 秒）
    func waitUntilLoaded(timeout: TimeInterval = 8) {
        let end = Date().addingTimeInterval(timeout)
        while loadedToken != token && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
}

/// 裏で読むファイルの情報
struct PreviewMeta {
    struct Child { var name: String; var icon: NSImage }
    var path: String
    var exists = false
    var isDir = false
    var kind = "書類"
    var sizeText: String?
    var modified: Date?
    var children: [Child] = []
    var childCount = 0

    /// 種類の名前（よくある物は日本語で。それ以外は OS の説明）
    static func kindName(_ t: UTType?, isDir: Bool) -> String {
        if isDir { return "フォルダ" }
        guard let t else { return "書類" }
        let table: [(UTType, String)] = [(.pdf, "PDF 書類"), (.image, "画像"), (.movie, "動画"), (.audio, "音声"),
                                         (.sourceCode, "コード"), (.html, "HTML"), (.json, "JSON"), (.text, "テキスト"),
                                         (.spreadsheet, "表計算"), (.presentation, "プレゼンテーション"), (.archive, "圧縮ファイル")]
        let ext = t.preferredFilenameExtension.map { " (.\($0))" } ?? ""
        for (u, n) in table where t.conforms(to: u) { return n + ext }
        return t.localizedDescription ?? "書類"
    }

    init(path: String) {
        self.path = path
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return }
        exists = true
        isDir = (v.isDirectory ?? false) && !(v.isPackage ?? false)
        kind = Self.kindName(v.contentType, isDir: isDir)
        modified = v.contentModificationDate
        if isDir {
            let fm = FileManager.default
            let names = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            childCount = names.count
            sizeText = "\(names.count) 項目"
            children = names.prefix(14).map { n in
                let i = NSWorkspace.shared.icon(forFile: (path as NSString).appendingPathComponent(n))
                i.size = NSSize(width: 32, height: 32)
                return Child(name: n, icon: i)
            }
        } else if let s = v.fileSize {
            sizeText = ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)
        }
    }
}
