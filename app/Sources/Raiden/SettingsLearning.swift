import AppKit
import RaidenCore

/// 設定の「学習」タブ: 選んだ結果を覚える・辞書（言い方 → アプリ / ファイル・フォルダ / 「#」の条件）・
/// 保存した絞り込み（#仕事のPDF）・よく使う組み合わせ（検索の記録から）・選んだ記録
final class LearningPaneState {
    /// 辞書の編集中の行（index nil は新しく足す）
    struct DictDraft { var index: Int?; var phrase: String; var target: DictEntry.Target; var key: String; var name: String }
    var dict: DictDraft?
    var dictError: String?
    weak var phraseField: NSTextField?
    weak var keyField: NSTextField?
    var savedName = ""
    var savedCommands = ""
    var savedError: String?
    weak var savedNameField: NSTextField?
    weak var savedCmdField: NSTextField?
}

extension SettingsWindowController {
    func learningPaneV2(_ st: LearningPaneState) -> [NSView] {
        guard let host else { return [] }
        let s = host.settings
        var out: [NSView] = [header(.learning, "辞書・保存した絞り込み・選んで開いた記録で、次から候補の上に出します。")]
        out.append(card([
            formRow("brain", "選んだ結果を覚える", detail: "オフにしても、今までの記録は効きます",
                    trailing: [sSwitch(s.learn) { [weak self] on in self?.host?.updateSettings { $0.learn = on } }]),
        ]))

        // 辞書
        out.append(spacer(4))
        out.append(sectionTitle("辞書（\(Self.num(s.dictionary.count)) 件）", symbol: "book", trailing: [
            sButton("追加", symbol: "plus", small: true) { [weak self] in
                st.dict = .init(index: nil, phrase: "", target: .app, key: "", name: ""); st.dictError = nil; self?.reload()
            },
        ]))
        let dc = CardView()
        dc.add(formRow("info.circle", "言い方が入力に含まれたら行き先を先頭に出します（入力欄の ⌥↩・#alias でも足せます）",
                       height: 38, iconColor: SettingsStyle.faint))
        if st.dict != nil { for r in dictEditor(st) { dc.add(r) } }
        out.append(dc)
        let dl = ScrollList(maxHeight: 220, empty: "まだありません（例: 「黒い画面」→ ターミナル）")
        dl.setRows(s.dictionary.enumerated().map { i, e in
            let sym = e.target == .app ? "app.badge" : e.target == .filter ? "line.3.horizontal.decrease" : "doc"
            let icon = sIcon(sym, size: 13)
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let edit = sIconButton("pencil", tip: "直す") { [weak self] in
                st.dict = .init(index: i, phrase: e.phrase, target: e.target, key: e.target == .file ? RaidenSettings.tilde(e.key) : e.key, name: e.name)
                st.dictError = nil
                self?.reload()
            }
            let del = sIconButton("trash", tip: "消す") { [weak self] in
                self?.host?.updateSettings { if $0.dictionary.indices.contains(i) { $0.dictionary.remove(at: i) } }
                self?.reload()
            }
            let detail = e.target == .filter ? e.target.label : e.target.label + "  " + RaidenSettings.tilde(e.key)
            return itemRow(icon: icon, title: "「\(e.phrase)」 → \(e.name)", detail: detail, trailing: [edit, del])
        })
        out.append(dl)

        // 保存した絞り込み
        out.append(spacer(4))
        out.append(sectionTitle("保存した絞り込み（\(Self.num(s.savedFilters.count)) 件）", symbol: "bookmark"))
        let sc = CardView()
        sc.add(formRow("info.circle", "入力欄で #名前 と打つと呼び出せます（今のチップは ⌘S か #保存 名前 で保存）",
                       height: 38, iconColor: SettingsStyle.faint))
        for (i, sf) in s.savedFilters.enumerated() {
            let del = sIconButton("trash", tip: "消す") { [weak self] in
                self?.host?.updateSettings { if $0.savedFilters.indices.contains(i) { $0.savedFilters.remove(at: i) } }
                self?.reload()
            }
            sc.add(formRow("bookmark", "#" + sf.name, detail: sf.text, trailing: [del]))
        }
        sc.add(savedEditor(st))
        out.append(sc)

        // よく使う組み合わせ
        let combos = host.filterCombos()
        if !combos.isEmpty {
            out.append(spacer(4))
            out.append(sectionTitle("よく使う「#」の組み合わせ（検索の記録から）", symbol: "clock.arrow.circlepath"))
            let cc = CardView()
            for c in combos.prefix(8) {
                let name = sButton("名前を付ける", symbol: "bookmark", small: true) { [weak self] in
                    st.savedCommands = c.text; st.savedName = ""; st.savedError = nil; self?.reload()
                }
                cc.add(formRow("clock.arrow.circlepath", c.text, detail: "\(c.count) 回・最後 \(Self.date(c.lastUsed))", trailing: [name]))
            }
            out.append(cc)
        }

        // 選んだ記録
        let ex = host.learnedExamples()
        out.append(spacer(4))
        out.append(sectionTitle("選んで開いた記録（\(Self.num(ex.count)) 件）", symbol: "text.badge.checkmark",
                                trailing: [sButton("全部消す", symbol: "trash", small: true) { [weak self] in self?.confirmClearChosen() }]))
        let list = ScrollList(maxHeight: 200, empty: "まだありません")
        list.setRows(ex.prefix(500).map { e in
            let icon = sIcon(e.kind == "app" ? "app.badge" : e.kind == "folder" ? "folder" : "doc", size: 13)
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let del = sIconButton("trash", tip: "この記録を消す") { [weak self] in
                self?.host?.deleteLearned(e)
                self?.reload()
            }
            let meta = sLabel("\(e.count) 回・\(Self.date(e.lastUsed))", size: 11, color: SettingsStyle.subText)
            return itemRow(icon: icon, title: "「\(e.query)」 → \(e.name)", trailing: [meta, del])
        })
        out.append(list)
        return out
    }

    // MARK: 辞書の編集

    private func dictEditor(_ st: LearningPaneState) -> [NSView] {
        guard let d = st.dict else { return [] }
        let phrase = field(d.phrase, placeholder: "言い方（例: 黒い画面）")
        st.phraseField = phrase
        let targets = DictEntry.Target.allCases
        let popup = sPopup(targets.map(\.label), selected: targets.firstIndex(of: d.target) ?? 0) { [weak self] i in
            self?.keepDictText(st)
            st.dict?.target = targets[i]; st.dict?.key = ""; st.dict?.name = ""; st.dictError = nil
            self?.reload()
        }
        let r1 = line([phrase, sLabel("→", size: 13, color: SettingsStyle.subText), popup], stretch: phrase)
        let r2: NSView
        if d.target == .filter {
            let k = field(d.key, placeholder: "#ext pdf #in ~/Documents/仕事")
            st.keyField = k
            r2 = line([sIcon("line.3.horizontal.decrease", size: 13), k], stretch: k)
        } else {
            st.keyField = nil
            let shown = d.key.isEmpty ? (d.target == .app ? "アプリを選んでください" : "ファイルかフォルダを選んでください")
                                      : "\(d.name)  \(d.key)"
            let l = sLabel(shown, size: 12, color: d.key.isEmpty ? SettingsStyle.faint : SettingsStyle.text)
            l.lineBreakMode = .byTruncatingMiddle
            let pick = sButton("選ぶ…", symbol: d.target == .app ? "app.badge" : "doc", small: true) { [weak self] in
                self?.keepDictText(st)
                self?.pickDictTarget(st)
            }
            r2 = line([sIcon(d.target == .app ? "app.badge" : "doc", size: 13), l, pick], stretch: l)
        }
        let err = sLabel(st.dictError ?? "", size: 11, color: SettingsStyle.warn)
        let cancel = sButton("やめる", small: true) { [weak self] in st.dict = nil; st.dictError = nil; self?.reload() }
        let save = sButton(d.index == nil ? "足す" : "直す", symbol: "checkmark", small: true) { [weak self] in self?.saveDict(st) }
        return [r1, r2, line([err, cancel, save], stretch: err)]
    }

    private func keepDictText(_ st: LearningPaneState) {
        if let p = st.phraseField { st.dict?.phrase = p.stringValue }
        if let k = st.keyField { st.dict?.key = k.stringValue }
    }

    private func pickDictTarget(_ st: LearningPaneState) {
        guard let d = st.dict else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = d.target == .file
        p.treatsFilePackagesAsDirectories = false
        p.allowsMultipleSelection = false
        p.prompt = "これにする"
        p.directoryURL = URL(fileURLWithPath: d.target == .app ? "/Applications" : NSHomeDirectory())
        if d.target == .app { p.allowedContentTypes = [.application] }
        guard p.runModal() == .OK, let url = p.url else { return }
        let path = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        st.dict?.key = d.target == .file ? RaidenSettings.tilde(path) : path
        st.dict?.name = d.target == .app ? FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                                         : url.lastPathComponent
        st.dictError = nil
        reload()
    }

    private func saveDict(_ st: LearningPaneState) {
        keepDictText(st)
        guard let d = st.dict, let host else { return }
        let e = DictEntry(phrase: d.phrase, target: d.target, key: d.key, name: d.target == .filter ? "" : d.name)
        if let pr = e.problem { st.dictError = pr; reload(); return }
        host.updateSettings { s in
            if let i = d.index, s.dictionary.indices.contains(i) {
                s.dictionary[i] = e
                // 同じ言い方の別の行があれば外す（同じ言い方は 1 行）
                let k = Describe.normalize(e.phrase)
                s.dictionary = s.dictionary.enumerated().filter { $0.offset == i || Describe.normalize($0.element.phrase) != k }.map(\.element)
            } else {
                s.dictionary = PhraseDictionary.adding(e, to: s.dictionary).list
            }
        }
        st.dict = nil
        st.dictError = nil
        reload()
    }

    // MARK: 保存した絞り込みの追加

    private func savedEditor(_ st: LearningPaneState) -> NSView {
        let name = field(st.savedName, placeholder: "名前（仕事のPDF）")
        let cmds = field(st.savedCommands, placeholder: "#ext pdf #in ~/Documents/仕事")
        st.savedNameField = name; st.savedCmdField = cmds
        name.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let err = sLabel(st.savedError ?? "", size: 11, color: SettingsStyle.warn)
        let add = sButton("保存", symbol: "plus", small: true) { [weak self] in self?.saveFilter(st) }
        let v = NSStackView(views: [line([sLabel("#", size: 13, color: SettingsStyle.subText), name, cmds, add], stretch: cmds)])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0
        if st.savedError != nil { v.addArrangedSubview(line([err], stretch: err)) }
        for x in v.arrangedSubviews { x.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    private func saveFilter(_ st: LearningPaneState) {
        st.savedName = st.savedNameField?.stringValue ?? st.savedName
        st.savedCommands = st.savedCmdField?.stringValue ?? st.savedCommands
        let name = SavedFilter.clean(st.savedName)
        if let pr = SavedFilter.problem(name: name) { st.savedError = pr; reload(); return }
        let f = QueryFilters.parse(st.savedCommands + " ")
        let cmds = f.parsed.compactMap(FilterMemory.canonical)
        if !f.notes.isEmpty { st.savedError = f.notes.joined(separator: "、"); reload(); return }
        if cmds.isEmpty { st.savedError = "#ext pdf のように条件を書いてください"; reload(); return }
        host?.updateSettings { s in
            s.savedFilters.removeAll { Describe.normalize($0.name) == Describe.normalize(name) }
            s.savedFilters.append(SavedFilter(name: name, commands: cmds))
        }
        st.savedName = ""; st.savedCommands = ""; st.savedError = nil
        reload()
    }

    private func confirmClearChosen() {
        let a = NSAlert()
        a.messageText = "選んで開いた記録を全部消しますか？"
        a.informativeText = "「言い方 → 物」の記録がすべて消え、元に戻せません。辞書と保存した絞り込みは残ります。"
        a.addButton(withTitle: "全部消す")
        a.addButton(withTitle: "やめる")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        host?.clearLearned()
        reload()
    }

    // MARK: 部品

    private func field(_ s: String, placeholder: String) -> NSTextField {
        let f = KField(text: s)
        f.placeholderString = placeholder
        f.font = K.mono(12)
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    /// 横に並べた 1 行（stretch を伸ばす）
    private func line(_ views: [NSView], stretch: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let st = NSStackView(views: views)
        st.orientation = .horizontal
        st.spacing = 8
        st.alignment = .centerY
        st.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(st)
        for v in views where v !== stretch { v.setContentHuggingPriority(.required, for: .horizontal) }
        stretch.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stretch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 40),
            st.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            st.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            st.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }
}

extension SettingsWindowController {
    /// 記録タブの「見つからなかった言い方」から辞書に足す: 行き先のアプリ・ファイル・フォルダを選ぶ（同じ言い方は置き換える）
    func addDictionary(phrase: String) {
        let p = NSOpenPanel()
        p.title = "「\(phrase)」の行き先を選ぶ"
        p.prompt = "辞書に足す"
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.treatsFilePackagesAsDirectories = false
        p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard p.runModal() == .OK, let url = p.url else { return }
        let path = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        let e = path.hasSuffix(".app")
            ? DictEntry(phrase: phrase, target: .app, key: path, name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""))
            : DictEntry(phrase: phrase, target: .file, key: path, name: url.lastPathComponent)
        host?.updateSettings { $0.dictionary = PhraseDictionary.adding(e, to: $0.dictionary).list }
        reload()
    }
}
