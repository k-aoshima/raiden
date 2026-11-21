import AppKit
import UniformTypeIdentifiers
import RaidenCore

/// 入力欄の絞り込みコマンド（#kind ss #date 7d …）の画面側。SearchPanelController からは数か所だけ呼ぶ。
///
///   「#」を打つと、よく使う組み合わせ・保存した名前・コマンドの一覧、「#date 」で値の候補（件数つき）を候補の場所に出す。
///   ↑↓ で選び、Enter / Tab で決める。値まで決まったコマンドはチップ（committed）にして入力欄から抜き、入力欄の下に並べる。
///   入力欄の先頭で Backspace / ← を押すと最後のチップを外してそのコマンドの値の一覧に戻る（続けて押すと前のチップの一覧へ）。⌘Backspace で全部のチップを消す。チップの × を押してもその 1 つを消す。
///   打ちかけの値は一覧の先頭の行を Tab / ↩ で決める。一覧が出ている間の Esc は一覧だけ閉じる。
///   「#」を打たなくても、「pdf」「先週」のような言葉から絞り込みの候補を入力欄の下に薄く出し、Tab / → で決めたときだけチップにする。
///   「#保存 名前」（⌘S）で今のチップに名前を付けて保存、「#alias 言い方」で辞書に足す（行き先を選ぶ状態になる）。
final class FilterInput {
    weak var panel: SearchPanelController?
    private weak var field: NSTextField?
    /// 値まで決まったコマンド（"#date 7d"）。付けた順
    private(set) var committed: [String] = []
    private(set) var palette: FilterCompletion.Palette?
    private var dismissedText: String?
    /// 「#」を打たずに出す絞り込みの候補（入力欄の下）
    private(set) var suggestions: [FilterSuggest.Suggestion] = []
    /// 入力欄の下に一度だけ出す一言（「#仕事のPDF を保存しました」）。次に打つと消える
    private(set) var notice: String?
    /// #alias の行き先を選んでいる間の言い方と、元の入力欄（取りやめたら戻す）
    private(set) var aliasPhrase: String?
    private var aliasBackup: (text: String, committed: [String])?
    /// ← / Backspace で前の条件へ戻したときの入力欄の文字と、打っていた言葉（触らずにもう一度押したらさらに戻る）
    private var stepBack: (shown: String, rest: String)?
    /// 値の候補の件数を数える口（AppDelegate が渡す。今は Engine.filterContext、一覧が無くなったら Spotlight 側の物）
    var context: (() -> FilterSource?)?
    /// 検索の記録から覚えた使い方（よく使う組み合わせ・値・場所・選ばずに閉じた言い方）
    var memory: () -> FilterMemory = { .empty }
    /// 名前を付けて保存したとき（AppDelegate が settings.json に書く）。上書きなら true を返す
    var onSave: ((SavedFilter) -> Bool)?
    /// 辞書に足したとき（AppDelegate が settings.json に書く）。置き換えたなら true を返す
    var onAddDictionary: ((DictEntry) -> Bool)?
    /// 見本・確かめ用の基準日
    var now: () -> Date = { Date() }
    /// クリップボードの履歴（#date・#from・#to の一覧の件数を数える。AppDelegate が Store.allClips を渡す）
    var clips: () -> [ClipItem] = { [] }

    var isPickingAlias: Bool { aliasPhrase != nil }
    /// 一覧の上に絞り込みの問いを出している（出している間は「続けて」の候補を出さない）
    var asking = false
    /// クリップボードの履歴を出している間（専用のキーか #clip）。入力欄の文字で履歴を絞る
    private(set) var clipMode = false

    func attach(_ panel: SearchPanelController, field: NSTextField, content: NSView) {
        self.panel = panel
        self.field = field
    }

    func reset() {
        committed = []
        palette = nil
        dismissedText = nil
        suggestions = []
        notice = nil
        aliasPhrase = nil
        aliasBackup = nil
        stepBack = nil
        clipMode = false
        panel?.setPlaceholder(nil)
    }

    /// 検索に渡す文字（チップ＋入力欄）。コマンドが無ければ今までどおり前後の空白を落とす。
    /// コマンドがあるときは後ろの空白を残す（打ちかけか打ち終えたかの見分けに使う）。
    /// #alias の行き先を選んでいる間は入力欄の文字（空なら言い方そのもの）で探す
    var currentQuery: String {
        let text = field?.stringValue ?? ""
        if clipMode { return "#clip " + text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let a = aliasPhrase {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? a : t
        }
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
        notice = nil
        stepBack = nil
        if aliasPhrase == nil, !clipMode, let ex = FilterCompletion.extractCommitted(field.stringValue, now: now()) {
            committed += ex.commands
            field.stringValue = ex.text
            moveCaretToEnd()
        }
        refresh()
    }

    /// 一覧を出し直し、出さないときは検索する
    func refresh() {
        guard let field, let panel else { return }
        // 「#clip 」「#cb 」まで打ったら履歴の状態に切り替える（後ろの言葉はそのまま入力欄に残す）
        if !clipMode, aliasPhrase == nil, let rest = QueryFilters.clipText(field.stringValue),
           !rest.isEmpty || field.stringValue.last?.isWhitespace == true {
            beginClip(rest)
            return
        }
        if clipMode {
            // 「#date 」「#from 」などを打っている間は値の一覧（履歴の中の件数つき）
            suggestions = []
            let text = field.stringValue
            if dismissedText != text { dismissedText = nil }
            palette = dismissedText == nil ? ClipCompletion.palette(for: text, clips: clips(), now: now()) : nil
            if let p = palette {
                panel.setResults(paletteSections(p), query: currentQuery, extra: [paletteHeader(p)], palette: true)
            } else {
                panel.onQuery?(currentQuery)
            }
            return
        }
        if aliasPhrase != nil {
            palette = nil; suggestions = []
            panel.onQuery?(currentQuery)
            return
        }
        let text = field.stringValue
        if dismissedText != text { dismissedText = nil }
        let mem = memory()
        let src = context?()
        palette = dismissedText == nil
            ? FilterCompletion.palette(for: text, committed: committed, context: src, memory: mem, now: now()) : nil
        suggestions = palette == nil ? FilterSuggest.suggest(text, committed: committed, memory: mem, source: src) : []
        if let p = palette {
            panel.setResults(paletteSections(p), query: currentQuery, extra: committedBar() + [paletteHeader(p)], palette: true)
        } else {
            panel.onQuery?(currentQuery)
        }
    }

    /// 件数を数える口の答えが後から届いたとき（Spotlight の問い合わせが終わったとき）に呼ぶ。一覧が出ていれば出し直す
    func sourceDidUpdate() {
        if palette != nil { refresh() }
    }

    // MARK: キー

    /// 一覧・チップ・言葉からの候補用のキー。扱ったら true（SearchPanelController の doCommandBy の先頭で呼ぶ）
    func handle(_ sel: Selector) -> Bool {
        guard let field, let panel else { return false }
        let sel0 = field.currentEditor()?.selectedRange ?? NSRange(location: 0, length: 0)
        let atEnd = sel0.location >= (field.stringValue as NSString).length
        let atStart = sel0.location == 0 && sel0.length == 0
        if clipMode, let p = palette {
            // 履歴の絞り込みの一覧: Enter / Tab で決める、Esc で一覧だけ閉じる（↑↓ は一覧）
            switch sel {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                let items = displayed(p)
                if items.indices.contains(panel.selectedRow) { accept(items[panel.selectedRow], p) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                dismissedText = field.stringValue
                refresh()
                return true
            default: break
            }
        }
        if clipMode {
            switch sel {
            case #selector(NSResponder.cancelOperation(_:)):
                // 打った言葉があれば消す、無ければ閉じる
                if field.stringValue.isEmpty { return false }
                field.stringValue = ""; refresh(); return true
            case #selector(NSResponder.insertTab(_:)): return true
            case #selector(NSResponder.deleteBackward(_:)):
                guard field.stringValue.isEmpty else { return false }
                endClip(); return true
            default: return false   // ↑↓ は一覧、Enter は SearchPanelController.openSelected
            }
        }
        if aliasPhrase != nil {
            switch sel {
            case #selector(NSResponder.cancelOperation(_:)): cancelAlias(); return true
            case #selector(NSResponder.insertTab(_:)): return true
            default: return false   // ↑↓ は一覧、Enter は SearchPanelController.openSelected → pickAlias
            }
        }
        if let p = palette {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                let items = displayed(p)
                if items.indices.contains(panel.selectedRow) { accept(items[panel.selectedRow], p) }
                return true
            case #selector(NSResponder.insertTab(_:)):
                let items = displayed(p)
                if items.indices.contains(panel.selectedRow) { accept(items[panel.selectedRow], p) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                dismissedText = field.stringValue
                refresh()
                return true
            default:
                break
            }
        }
        switch sel {
        case #selector(NSResponder.insertTab(_:)):
            // 言葉からの候補を決める。無ければ何もしない（フォーカスを入力欄から動かさない）
            if let s = suggestions.first { acceptSuggestion(s) }
            return true
        case #selector(NSResponder.moveRight(_:)):
            if atEnd, palette == nil, let s = suggestions.first { acceptSuggestion(s); return true }
            return false
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.moveLeft(_:)):
            // ← / Backspace で 1 つ前の条件へ戻る: 最後のチップを外し、そのコマンドの値の一覧（「#type 」）を出す。
            // 戻した直後（入力欄を触っていない間）にもう一度押すと、さらに前のチップのコマンドの一覧へ
            if let sb = stepBack, field.stringValue == sb.shown { stepBackOnce(rest: sb.rest); return true }
            guard atStart, !committed.isEmpty else { return false }
            stepBackOnce(rest: field.stringValue)
            return true
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):
            guard field.stringValue.isEmpty, !committed.isEmpty else { return false }
            committed.removeAll()
            refresh()
            panel.focusField()
            return true
        default:
            return false
        }
    }

    private func accept(_ item: FilterCompletion.Item, _ p: FilterCompletion.Palette) {
        guard let field else { return }
        switch p.mode {
        case .save:
            guard !item.insert.isEmpty else { return }
            let sf = SavedFilter(name: item.insert, commands: item.commits)
            let over = onSave?(sf) ?? false
            field.stringValue = FilterCompletion.accept(item, palette: p, text: field.stringValue).text
            notice = "#\(sf.name) を" + (over ? "置き換えました" : "保存しました") + "（\(sf.text)）"
            refresh()
            panel?.focusField()
            return
        case .alias:
            guard !item.insert.isEmpty else { return }
            beginAlias(item.insert, restText: FilterCompletion.accept(item, palette: p, text: field.stringValue).text)
            return
        default:
            break
        }
        let r = FilterCompletion.accept(item, palette: p, text: field.stringValue)
        if let c = r.commit { committed.append(c) }
        committed += r.commits
        field.stringValue = r.text
        refresh()
        // 決めた後も入力欄で続けて打てるように（行を押して決めたときも）
        panel?.focusField()
    }

    /// 一覧の行を押したとき（Enter と同じ）
    func acceptRow(_ i: Int) {
        guard let p = palette else { return }
        let items = displayed(p)
        if items.indices.contains(i) { accept(items[i], p) }
    }

    /// 次に付けそうなコマンドを押したとき（よく使う組み合わせの続きならまとめて）
    func acceptNext(_ insert: String, commits: [String] = []) {
        committed += commits.isEmpty ? [insert] : commits
        refresh()
        panel?.focusField()
    }

    /// 入力全体を書き換える（「探し方を変える」の案）。コマンドはチップに、残りは入力欄に
    func replaceQuery(_ q: String) {
        guard let field else { return }
        if let ex = FilterCompletion.extractCommitted(q + " ", now: now()) {
            committed = ex.commands
            field.stringValue = ex.text.trimmingCharacters(in: .whitespaces)
        } else {
            committed = []
            field.stringValue = q
        }
        stepBack = nil
        refresh()
        panel?.focusField()
    }

    /// 言葉からの候補を決める: チップにして、入力からその言葉を外す
    func acceptSuggestion(_ s: FilterSuggest.Suggestion) {
        guard let field else { return }
        committed += s.commands
        field.stringValue = FilterSuggest.accept(s, text: field.stringValue)
        refresh()
        panel?.focusField()
    }

    /// 1 つ前の条件へ戻る。最後のチップを外して入力欄を「（打っていた言葉） #type 」にし、値の一覧を出す。
    /// チップが残っていなければコマンドを消して打っていた言葉だけに戻す
    private func stepBackOnce(rest r: String) {
        guard let field, let panel else { return }
        let rest = r.trimmingCharacters(in: .whitespaces)
        if let last = committed.popLast() {
            let cmd = last.split(separator: " ", maxSplits: 1).first.map(String.init) ?? last
            let shown = (rest.isEmpty ? "" : rest + " ") + cmd + " "
            field.stringValue = shown
            stepBack = (shown, rest)
        } else {
            field.stringValue = rest
            stepBack = nil
        }
        dismissedText = nil
        refresh()
        panel.focusField()
    }

    /// チップの × を押したとき: そのコマンドのチップを全部外す
    func removeChip(_ c: QueryFilters.Command) {
        committed.removeAll { QueryFilters.parse($0).order.contains(c) }
        refresh()
        panel?.focusField()
    }

    /// ⌘S: 今のチップに名前を付けて保存する（入力欄を「#保存 」にする。打っていた言葉は後ろに残す）
    func beginSave() {
        guard let field, aliasPhrase == nil else { return }
        field.stringValue = "#保存 "
        notice = nil
        refresh()
        moveCaretToEnd()
    }

    // MARK: クリップボード（専用のキー・#clip）

    /// 履歴の状態にする。チップは外し、入力欄の文字で履歴を絞る
    func beginClip(_ text: String = "") {
        guard let field else { return }
        clipMode = true
        aliasPhrase = nil; aliasBackup = nil
        // 付けていた期間（#date 昨日）は履歴の絞り込みとして持ち越す。ほかのコマンドはファイル用なので外す
        let dates = committed.filter { QueryFilters.parse($0).dates[.date] != nil }
        committed = []
        palette = nil
        dismissedText = nil
        field.stringValue = (dates + [text]).filter { !$0.isEmpty }.joined(separator: " ")
        notice = nil
        panel?.setPlaceholder("クリップボードの履歴　# で日付・アプリ")
        refresh()
        moveCaretToEnd()
        panel?.focusField()
    }

    /// 履歴の状態をやめて、ふつうの入力欄に戻る（入力欄が空の Backspace）
    func endClip() {
        clipMode = false
        field?.stringValue = ""
        panel?.setPlaceholder(nil)
        refresh()
        panel?.focusField()
    }

    // MARK: 辞書（#alias）

    /// 言い方を決めて、行き先を選ぶ状態にする。入力欄は空にして、打てば名前で絞れる（最初は言い方そのもので探す）
    func beginAlias(_ phrase: String, restText: String? = nil) {
        guard let field else { return }
        aliasBackup = (restText ?? field.stringValue, committed)
        aliasPhrase = phrase
        committed = []
        field.stringValue = ""
        palette = nil
        panel?.setPlaceholder("「\(phrase)」→ どれに？")
        refresh()
        panel?.focusField()
    }

    /// 行き先を選んだとき（SearchPanelController.openSelected から）。辞書に足して元の入力欄に戻る
    func pickAlias(_ c: Candidate) {
        guard let phrase = aliasPhrase, let e = DictionaryLookup.entry(phrase: phrase, c) else { return }
        let replaced = onAddDictionary?(e) ?? false
        endAlias()
        notice = DictionaryLookup.message(e, replaced: replaced)
        refresh()
    }

    func cancelAlias() {
        endAlias()
        refresh()
    }

    private func endAlias() {
        let b = aliasBackup
        aliasPhrase = nil
        aliasBackup = nil
        committed = b?.committed ?? []
        field?.stringValue = b?.text ?? ""
        panel?.setPlaceholder(nil)
        panel?.focusField()
    }

    /// ⌥Enter: 今の言葉（コマンドを抜いた物）→ 選んだ候補 を辞書に足す。言葉が無ければ何もしない
    @discardableResult
    func addToDictionary(_ c: Candidate) -> String? {
        let phrase = QueryFilters.parse(currentQuery).text.trimmingCharacters(in: .whitespaces)
        guard !phrase.isEmpty, aliasPhrase == nil, !clipMode, let e = DictionaryLookup.entry(phrase: phrase, c) else { return nil }
        let replaced = onAddDictionary?(e) ?? false
        return DictionaryLookup.message(e, replaced: replaced)
    }

    private func moveCaretToEnd() {
        guard let field, let ed = field.currentEditor() else { return }
        ed.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    // MARK: 見た目

    /// 件数のある値を先に、0 件は下に回す（行数は検索の候補と同じ 9 まで。コマンドの一覧は全部）
    func displayed(_ p: FilterCompletion.Palette) -> [FilterCompletion.Item] {
        let n = p.mode == .commands ? 20 : SearchPanelController.maxRows
        // 0 件は後ろへ。ただし打ったとおりの値（並べ方で先頭にした物）はそのまま先頭
        let typed = p.partial.isEmpty ? nil : p.items.first.flatMap { Describe.normalize($0.insert) == Describe.normalize(p.partial) ? $0 : nil }
        let rest = typed == nil ? p.items : Array(p.items.dropFirst())
        return Array(((typed.map { [$0] } ?? []) + rest.filter { $0.count != 0 } + rest.filter { $0.count == 0 }).prefix(n))
    }

    private func paletteSections(_ p: FilterCompletion.Palette) -> [ResultSection] {
        let rows = displayed(p).map { it -> RowItem in
            var title = it.title
            // コマンドの一覧は、見出し（時期）の右にコマンド（#date）を藍で添える。ほかは今までどおり見出しに続ける
            let tagged = p.mode == .commands && !it.title.hasPrefix("#")
            if !it.alias.isEmpty && !tagged { title += "    " + it.alias }
            if let c = it.count { title += "  ·  \(FilterCompletion.countText(c)) 件" }
            let hint = p.mode == .save || p.mode == .alias ? "↩ 決める" : "↩ 選ぶ　Tab"
            // アプリの行（#from・#to）はそのアプリのアイコン
            let appIcon = it.bundleID.isEmpty ? nil
                : NSWorkspace.shared.urlForApplication(withBundleIdentifier: it.bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            var row = RowItem(title: title, sub: it.detail, iconImage: appIcon ?? symbol(it.symbol, size: 18, weight: .regular),
                              hint: it.badge.isEmpty ? hint : it.badge + "　" + hint)
            if tagged {
                // カードの右端はコマンドの名前だけ（#date）。短い別名は打てば当たる
                row.tag = it.alias.split(separator: " ").first.map(String.init) ?? it.alias
                row.card = true
                row.iconImage = symbol(it.symbol, size: 15, weight: .medium)
            }
            return row
        }
        return [ResultSection(title: "候補", symbol: "list.bullet", items: rows)]
    }

    /// 一覧を出している間も、もう付いている条件（チップ）を一覧の上に出す（今どこまで絞っているか分かるように）
    private func committedBar() -> [(NSView, CGFloat)] {
        let chips = QueryFilters.parse(committed.joined(separator: " "), now: now()).chips
        if chips.isEmpty { return [] }
        return [(ChipBar(chips: chips, notes: [], next: [], onNext: { _ in },
                         onRemove: { [weak self] c in self?.removeChip(c) }), ChipBar.height)]
    }

    private func paletteHeader(_ p: FilterCompletion.Palette) -> (NSView, CGFloat) {
        let title: String, sym: String
        switch p.mode {
        case .commands: title = "何を覚えていますか"; sym = "square.stack.3d.up"
        case .values(let c) where [.date, .modified, .created].contains(c):
            // 日付の書き方は一覧に出ないので見出しで見せる
            title = "\(c.name) の値　11-14・11月・11-1..11-14 とも打てる"; sym = "calendar"
        case .values(let c): title = "\(c.name) の値" + (context?() == nil ? "" : "（件数はほかの条件の中で）"); sym = "line.3.horizontal.decrease"
        case .clipCommands: title = "履歴の絞り込み"; sym = "doc.on.clipboard"
        case .clipValues(let k):
            title = k == "date" ? "#date の値（コピーした日）　11-14・11月・11-1..11-14 とも打てる"
                : k == "from" ? "#from の値（コピーしたアプリ）" : "#to の値（貼ったアプリ）"
            sym = k == "date" ? "calendar" : "app"
        case .save: title = "今の条件に名前を付けて保存"; sym = "bookmark"
        case .alias: title = "辞書に足す言い方"; sym = "book"
        }
        let keys = p.mode == .commands ? "↑↓ ←→ で選んで ↩ / Tab　Esc で閉じる" : "↑↓ で選んで ↩ / Tab　Esc で閉じる"
        return (LabelLine(title, symbol: sym, detail: keys), SearchPanelController.headerHeight)
    }

    /// 入力欄の下に出す行（一言・行き先を選ぶ案内・チップ・知らせ・次に付けそうなコマンド・言葉からの候補・「条件に合う物はありません」）。
    /// 一覧を出していないときに使う
    func topLines(sections: [ResultSection], query: String, preparing: Bool) -> [(NSView, CGFloat)] {
        var out: [(NSView, CGFloat)] = []
        if let n = notice {
            out.append((LabelLine(n, symbol: "checkmark.circle", detail: nil), SearchPanelController.headerHeight + 4))
        }
        if let a = aliasPhrase {
            out.append((LabelLine("「\(a)」→ どれに？", symbol: "book", detail: "打つと名前で絞れます　↑↓ で選んで ↩ で辞書に足す　Esc でやめる"),
                        SearchPanelController.headerHeight + 4))
            return out
        }
        if clipMode { return out }   // 履歴の絞り込みは入力欄の文字のまま（チップにしない）
        let f = QueryFilters.parse(query, now: now())
        if f.hasSyntax {
            let next = !asking && (field?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? false)
                ? FilterCompletion.next(f, context: context?(), memory: memory(), now: now()) : []
            if !f.chips.isEmpty || !f.notes.isEmpty || !next.isEmpty {
                out.append((ChipBar(chips: f.chips, notes: f.notes, next: next,
                                    onNext: { [weak self] it in self?.acceptNext(it.insert, commits: it.commits) },
                                    onRemove: { [weak self] c in self?.removeChip(c) }), ChipBar.height))
            }
        }
        if !suggestions.isEmpty {
            out.append((SuggestBar(suggestions) { [weak self] s in self?.acceptSuggestion(s) }, ChipBar.height))
        }
        if f.isActive && sections.allSatisfy({ $0.items.isEmpty }) {
            let what = f.allowsFiles ? "ファイル" : "アプリ"
            let msg = preparing && f.allowsFiles ? "ファイル準備中…" : "この条件に合う\(what)はありません。"
            out.append((LabelLine(msg, symbol: "line.3.horizontal.decrease.circle", big: true, plain: true), SearchPanelController.messageHeight))
        }
        return out
    }

}

/// 押せる札（クリックで handler）
class TapPill: NSView {
    var onTap: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onTap?() }
}

/// 入力欄の下の 1 行: 効いている絞り込みのチップ（アイコン付き・× で消せる）、知らせ（「#size は使えません」）、次に付けそうなコマンド
final class ChipBar: NSView {
    static let height: CGFloat = 32

    init(chips: [QueryFilters.Chip], notes: [String], next: [FilterCompletion.Item],
         onNext: @escaping (FilterCompletion.Item) -> Void, onRemove: @escaping (QueryFilters.Command) -> Void) {
        super.init(frame: .zero)
        let stack = Self.row(in: self)
        for c in chips {
            let p = Self.pill(c.label, symbol: c.symbol, filled: true, closable: true)
            // 「先月ごろ」のような幅のある時期は点線の札（境目の外も少し入る）
            if c.label.hasSuffix("ごろ") { (p as? PillView)?.soft = true }
            p.onTap = { onRemove(c.command) }
            p.toolTip = "押すとこの条件を外す"
            stack.addArrangedSubview(p)
        }
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
            stack.addArrangedSubview(Self.caption("続けて"))
            for it in next {
                let b = Self.pill(it.title + (it.count.map { " " + FilterCompletion.countText($0) } ?? ""), symbol: it.symbol, filled: false)
                b.onTap = { onNext(it) }
                stack.addArrangedSubview(b)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    static func row(in v: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return stack
    }

    static func caption(_ s: String, symbol name: String? = nil) -> NSView {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = PanelStyle.faint
        guard let name else { return l }
        let icon = NSImageView(image: symbol(name, size: 10, weight: .medium) ?? NSImage())
        icon.contentTintColor = PanelStyle.faint
        let st = NSStackView(views: [icon, l])
        st.spacing = 4
        return st
    }

    /// 札 1 つ（アイコン＋文字）。filled: 効いている絞り込み（closable なら右に ×）、false: 押すと足せる候補（枠だけ）
    static func pill(_ text: String, symbol name: String, filled: Bool, closable: Bool = false, faint: Bool = false) -> TapPill {
        let v = PillView(filled: filled)
        let icon = NSImageView(image: symbol(name, size: 10, weight: .semibold) ?? NSImage())
        icon.contentTintColor = filled ? PanelStyle.indigo : PanelStyle.subText
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = filled ? PanelStyle.text : (faint ? PanelStyle.faint : PanelStyle.subText)
        var views: [NSView] = [icon, l]
        let x = NSImageView(image: symbol("xmark", size: 8, weight: .bold) ?? NSImage())
        x.contentTintColor = PanelStyle.faint
        if closable { views.append(x) }
        for e in views { e.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(e) }
        NSLayoutConstraint.activate([
            v.heightAnchor.constraint(equalToConstant: 22),
            icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            l.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            l.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        if closable {
            NSLayoutConstraint.activate([
                x.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: 5),
                x.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                x.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            ])
        } else {
            l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -9).isActive = true
        }
        return v
    }
}

/// 入力欄の下の 1 行: 「#」を打たずに出した絞り込みの候補（薄く。Tab で先頭を決める、押しても決まる）
final class SuggestBar: NSView {
    init(_ items: [FilterSuggest.Suggestion], onPick: @escaping (FilterSuggest.Suggestion) -> Void) {
        super.init(frame: .zero)
        let stack = ChipBar.row(in: self)
        stack.addArrangedSubview(ChipBar.caption("Tab で絞る", symbol: "line.3.horizontal.decrease"))
        for (i, s) in items.enumerated() {
            let p = ChipBar.pill(s.title + "  " + s.label, symbol: s.symbol, filled: false, faint: i > 0)
            p.onTap = { onPick(s) }
            p.toolTip = "「\(s.word)」から。押すか Tab で絞り込みにする"
            stack.addArrangedSubview(p)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 札の面（角丸。効いている絞り込みは薄い青の面、候補は枠だけ）
final class PillView: TapPill {
    let filled: Bool
    var soft = false { didSet { needsDisplay = true } }
    init(filled: Bool) { self.filled = filled; super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        if soft {
            PanelStyle.indigo.withAlphaComponent(0.06).setFill()
            p.fill()
            PanelStyle.indigo.withAlphaComponent(0.7).setStroke()
            p.lineWidth = 1
            p.setLineDash([3, 2], count: 2, phase: 0)
            p.stroke()
        } else if filled {
            PanelStyle.pillFill.setFill()
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
        Snapshot.capture(panel("#"), dir + "/option-commands.png")
        Snapshot.capture(panel("#date "), dir + "/option-date-values.png")
        Snapshot.capture(panel("#type ", committed: ["#date 7d"]), dir + "/option-values-with-chips.png")
        Snapshot.capture(panel("#date 11-1"), dir + "/option-date-typed.png")
        // クリップボードの履歴を #from で絞る
        let cl = [("Safari", 0, "com.apple.Safari"), ("Safari", -3600, "com.apple.Safari"), ("ターミナル", -7200, "com.apple.Terminal"),
                  ("プレビュー", -90000, "com.apple.Preview"), ("メモ", -200000, "com.apple.Notes")].enumerated().map { i, a in
            ClipItem(id: Int64(i), text: "サンプル \(i)", source: .init(bundleID: a.2, app: a.0, title: "", at: now.addingTimeInterval(TimeInterval(a.1))), count: 1, pastes: [])
        }
        let cp = SearchPanelController()
        cp.filterInput.now = { now }
        cp.filterInput.clips = { cl }
        cp.filterInput.beginClip("#from ")
        Snapshot.capture(cp, dir + "/clip-from.png")
        Snapshot.capture(panel("#kind sc"), dir + "/option-typing.png")

        // チップが 2 つ付いた状態（#kind ss #date 7d）。候補は見本
        let c = panel("", committed: ["#kind ss", "#date 7d"])
        let rows = files.filter { QueryFilters.parse("#kind ss #date 7d", now: now).matches($0) }.prefix(4).map {
            RowItem(title: $0.name, sub: RowItem.shortParent($0.path), iconImage: NSWorkspace.shared.icon(for: .png), hint: RowItem.fileHint)
        }
        let q = c.filterInput.currentQuery
        c.setResults([ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: Array(rows))], query: q)
        Snapshot.capture(c, dir + "/option-chips.png")

        // 候補が多いときの絞り込みの問い（一覧の上）。候補と件数は見本
        let ak = panel("見積")
        let akRows = [("見積書_サンプル.xlsx", "~/Documents/サンプル", UTType.spreadsheet), ("estimate_sample.pdf", "~/Downloads", UTType.pdf),
                      ("見積依頼_サンプル.md", "~/Documents/サンプル/メモ", UTType.plainText)].map {
            RowItem(title: $0.0, sub: $0.1, iconImage: NSWorkspace.shared.icon(for: $0.2), hint: RowItem.fileHint)
        }
        let akSplit = RecallSplit(title: "時期で絞り込む", total: 86, options: [
            .init(label: "今週", symbol: "clock", command: "#date 今週", count: 3), .init(label: "先月", symbol: "clock", command: "#date 先月", count: 41),
            .init(label: "今年", symbol: "clock", command: "#date 今年", count: 74), .init(label: "去年", symbol: "clock", command: "#date 去年", count: 12)])
        ak.setResults([ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: akRows)], query: ak.filterInput.currentQuery, split: akSplit)
        Snapshot.capture(ak, dir + "/recall-ask.png")
        // 答えた後: 「先月ごろ」（点線の札）と次の問い
        let ak2 = panel("見積", committed: ["#date 先月ごろ"])
        let akSplit2 = RecallSplit(title: "入手元で絞り込む", total: 41, options: [
            .init(label: "ダウンロード", symbol: "arrow.down.circle", command: "#src dl", count: 18),
            .init(label: "自分で作成", symbol: "pencil.and.outline", command: "#src mine", count: 15),
            .init(label: "メール添付", symbol: "envelope", command: "#src mail", count: 8)])
        ak2.setResults([ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: Array(akRows.prefix(2)))], query: ak2.filterInput.currentQuery, split: akSplit2)
        Snapshot.capture(ak2, dir + "/recall-ask2.png")
        // 長い場所の名前で 1 行に入りきらないときは折り返す
        let ak3 = panel("docx")
        let akSplit3 = RecallSplit(title: "場所で絞り込む", total: 2018, options: [
            .init(label: "sample-studio", symbol: "folder", command: "#path ~/Project/sample-studio", count: 724),
            .init(label: "sample-studio-wt-fonts", symbol: "folder", command: "#path ~/Project/sample-studio-wt-fonts", count: 274),
            .init(label: "sample-docs-archive", symbol: "folder", command: "#path ~/Documents/sample-docs-archive", count: 160),
            .init(label: "Downloads", symbol: "folder", command: "#path ~/Downloads", count: 92)])
        ak3.setResults([ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: akRows)], query: ak3.filterInput.currentQuery, split: akSplit3)
        Snapshot.capture(ak3, dir + "/recall-ask-wrap.png")
        // ⌘→: 選んでいるファイルを基準に #with / #near を選ぶ
        let bw = panel("見積")
        let bwRows = ["見積書_サンプル.pdf", "見積依頼_サンプル.md"].map {
            RowItem(.file(FileResult(file: FileEntry(path: home + "/Documents/サンプル/" + $0, mtime: t("2026-11-18 15:00")), score: 1)))
        }
        bw.setResults([ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: bwRows)], query: bw.filterInput.currentQuery)
        bw.askAboutSelected()
        Snapshot.capture(bw, dir + "/recall-base.png")
        bw.pickAsk(0)
        print(bw.filterInput.committed == ["#with ~/Documents/サンプル/見積書_サンプル.pdf"] && bw.queryText.isEmpty
              ? "  ok  ⌘→ → ⌘1 で #with のチップだけになる" : "  NG  ⌘→ → ⌘1: \(bw.filterInput.committed) 「\(bw.queryText)」")
        // 見つからないときの「探し方を変える」（件数は見本）
        let nf = panel("見積", committed: ["#date 先月", "#kind pdf"])
        let nfSplit = RecallSplit(title: "探し方を変える", total: 0, options: [
            .init(label: "「先月ごろ」に広げる", symbol: "clock", command: "#date 先月ごろ #kind pdf 見積", count: 4, replaces: true),
            .init(label: "本文から「見積」", symbol: "text.magnifyingglass", command: "#date 先月 #kind pdf #text 見積", count: 9, replaces: true),
            .init(label: "「PDF」を外す", symbol: "xmark.circle", command: "#date 先月 見積", count: 3, replaces: true)])
        nf.setResults([], query: nf.filterInput.currentQuery, split: nfSplit)
        Snapshot.capture(nf, dir + "/recall-notfound.png")

        // 絞り込みの長い一覧を時期の棚に分けた状態（行に「いつ・どこから」）。今の時刻からの見本
        let nowT = Int(Date().timeIntervalSince1970)
        func ent(_ p: String, hoursAgo: Int, dl: Bool = false, origin: String = "") -> FileEntry {
            let t = nowT - hoursAgo * 3600
            return FileEntry(path: home + p, name: (p as NSString).lastPathComponent, parentName: "", isDir: false, kind: "", families: [],
                             size: 1, mtime: dl ? t - 86400 * 30 : t, created: t, added: dl ? t : 0, lastUsed: dl ? 0 : t, usedDays: [],
                             downloaded: dl, origin: origin)
        }
        let shelfFiles = [
            ent("/Documents/サンプル/見積書_v3_サンプル.xlsx", hoursAgo: 1), ent("/Downloads/estimate_sample_1.pdf", hoursAgo: 3, dl: true, origin: "example.co.jp"),
            ent("/Documents/サンプル/見積依頼_サンプル.md", hoursAgo: 30), ent("/Downloads/estimate_sample_2.pdf", hoursAgo: 28, dl: true, origin: "example.com"),
            ent("/Documents/サンプル/見積_比較_サンプル.numbers", hoursAgo: 24 * 9), ent("/Documents/サンプル/見積_メモ_サンプル.txt", hoursAgo: 24 * 10),
            ent("/Downloads/quotation_sample.pdf", hoursAgo: 24 * 40, dl: true, origin: "example.org"),
            ent("/Documents/サンプル/見積_旧_サンプル.docx", hoursAgo: 24 * 70), ent("/Documents/サンプル/見積_下書き_サンプル.pages", hoursAgo: 24 * 75),
            ent("/Documents/サンプル/見積_去年_サンプル.xlsx", hoursAgo: 24 * 400),
        ]
        let shelfSec = ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: shelfFiles.map { RowItem(.file(FileResult(file: $0, score: 1))) })
        let sh = panel("見積", committed: ["#kind doc,pdf,xls"])
        sh.setResults(AppDelegate.timeShelves(shelfSec), query: sh.filterInput.currentQuery)
        Snapshot.capture(sh, dir + "/recall-shelves.png")

        // 何も打っていないときの最近の作業のまとまり（見本のファイル。今の時刻から）
        func usedAgo(_ p: String, min: Int) -> FileEntry {
            FileEntry(path: home + p, name: (p as NSString).lastPathComponent, parentName: "", isDir: false, kind: "", families: [], size: 1,
                      mtime: 0, created: 0, added: 0, lastUsed: nowT - min * 60, usedDays: [], downloaded: false)
        }
        let recentSample = [usedAgo("/Documents/サンプル/企画書_サンプル.key", min: 4), usedAgo("/Documents/サンプル/企画メモ_サンプル.md", min: 18),
                            usedAgo("/Documents/サンプル/画面案_サンプル.png", min: 35), usedAgo("/Desktop/スクリーンショット サンプル.png", min: 60 * 5),
                            usedAgo("/Desktop/議事録_サンプル.txt", min: 60 * 5 + 20), usedAgo("/Downloads/invoice_sample.pdf", min: 60 * 26)]
        let rp = SearchPanelController()
        rp.recentSections = {
            Recall.sessions(recentSample, projectRoot: { ($0 as NSString).deletingLastPathComponent }).map { ss in
                ResultSection(title: ss.title, symbol: "clock", items: ss.items.map { RowItem(.file(FileResult(file: $0, score: 0))) })
            }
        }
        rp.showRecent()
        Snapshot.capture(rp, dir + "/recall-recent.png")

        // #type app で全部出してスクロールした状態。アプリは OS 付属のもの（私的な名前は使わない）
        let appDirs = ["/System/Applications", "/System/Applications/Utilities"]
        let appPaths = appDirs.flatMap { d in
            ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).filter { $0.hasSuffix(".app") }.map { d + "/" + $0 }
        }.sorted { ($0 as NSString).lastPathComponent < ($1 as NSString).lastPathComponent }
        let all = panel("", committed: ["#type app"])
        let appRows = appPaths.map {
            RowItem(title: (($0 as NSString).lastPathComponent as NSString).deletingPathExtension, sub: $0, iconPath: $0, hint: RowItem.appHint)
        }
        all.setResults([ResultSection(title: "アプリ", symbol: "app.badge", items: appRows)], query: all.filterInput.currentQuery)
        all.select(min(18, max(0, appRows.count - 1)))
        Snapshot.capture(all, dir + "/option-all.png")

        // 「#」の直後: よく使う組み合わせ・保存した名前・コマンド（記録は見本）
        var mem = FilterMemory()
        mem.combos = FilterMemory.build(from: (0..<4).map { i in
            var e = SearchLogEntry(ts: Int(now.timeIntervalSince1970) - i * 86400, query: "#ext pdf #path Downloads", edits: [], candidates: [],
                                   dismissed: false, notFound: false, ms: 1)
            e.chosenRank = 1
            return e
        } + (0..<2).map { i in
            var e = SearchLogEntry(ts: Int(now.timeIntervalSince1970) - i * 86400, query: "#kind ss #date 7d", edits: [], candidates: [],
                                   dismissed: false, notFound: false, ms: 1)
            e.chosenRank = 1
            return e
        }, now: now).combos
        SavedFilters.set([SavedFilter(name: "仕事のPDF", commands: ["#ext pdf", "#path ~/Documents/サンプル"])])
        let combos = SearchPanelController()
        combos.filterInput.context = { ctx }
        combos.filterInput.now = { now }
        combos.filterInput.memory = { mem }
        combos.setQueryText("#")
        combos.filterInput.refresh()
        Snapshot.capture(combos, dir + "/option-combos.png")
        SavedFilters.set([])

        // 「#」を打たない言葉からの候補（「先週の pdf」→ #ext pdf・#date lastweek を薄く）。チップ 1 つ付き
        let sug = panel("先週の pdf 見積", committed: ["#path ~/Documents/サンプル"])
        let srows = files.filter { $0.name.hasPrefix("見積書") }.prefix(3).map {
            RowItem(title: $0.name, sub: RowItem.shortParent($0.path), iconImage: NSWorkspace.shared.icon(for: .pdf), hint: RowItem.fileHint)
        }
        sug.setResults([ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: Array(srows))], query: sug.filterInput.currentQuery)
        Snapshot.capture(sug, dir + "/option-suggest.png")

        // #alias の行き先を選ぶ状態（「黒い画面」→ どれに？）。アプリは OS 付属
        let al = panel("#alias 黒い画面")
        al.filterInput.beginAlias("黒い画面", restText: "")
        let pick = ["/System/Applications/Utilities/Terminal.app", "/System/Applications/Utilities/Console.app",
                    "/System/Applications/Utilities/Activity Monitor.app"].filter { FileManager.default.fileExists(atPath: $0) }.map {
            RowItem(title: FileManager.default.displayName(atPath: $0).replacingOccurrences(of: ".app", with: ""), sub: $0, iconPath: $0, hint: "↩ 辞書に足す")
        }
        al.setResults([ResultSection(title: "アプリ", symbol: "app.badge", items: pick),
                       ResultSection(title: "ファイル・フォルダ", symbol: "folder",
                                     items: [RowItem(title: "黒い画面のメモ_サンプル.md", sub: "~/Documents/サンプル", iconImage: NSWorkspace.shared.icon(for: .plainText), hint: "↩ 辞書に足す")])],
                      query: al.filterInput.currentQuery)
        Snapshot.capture(al, dir + "/option-alias.png")
    }
}

/// 入力欄が一覧を選んだ後も打てるかの確かめ（Raiden --test-focus）。パネルは画面に出さない
enum FocusTest {
    static func run() -> Bool {
        var fails = 0, checks = 0
        func expect(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { fails += 1 }
            print((ok ? "  ok  " : "  NG  ") + what)
        }
        let ctx = FilterContext(files: [FileEntry(path: NSHomeDirectory() + "/Desktop/見本.png", mtime: Int(Date().timeIntervalSince1970))], appCount: 5)
        func make() -> SearchPanelController {
            let c = SearchPanelController()
            c.filterInput.context = { ctx }
            c.focusField()
            return c
        }
        func tv(_ c: SearchPanelController) -> NSTextView? { c.fieldEditor as? NSTextView }
        func type(_ c: SearchPanelController, _ s: String) {
            for ch in s { tv(c)?.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
        func key(_ c: SearchPanelController, _ sel: Selector) { tv(c)?.doCommand(by: sel) }
        func focused(_ c: SearchPanelController) -> Bool {
            guard let ed = c.fieldEditor else { return false }
            return c.panel.firstResponder === ed
        }

        // 1) 「#t 」→ ↓↓ でアプリ → Enter → 続けて「sa」
        var c = make()
        expect(focused(c), "最初から入力欄が打てる")
        type(c, "#t ")
        expect(c.filterInput.palette?.mode == .values(.type), "「#t 」で値の候補")
        let appRow = c.filterInput.palette.map { c.filterInput.displayed($0).firstIndex { $0.insert == "app" } ?? 0 } ?? 0
        for _ in 0..<appRow { key(c, #selector(NSResponder.moveDown(_:))) }
        key(c, #selector(NSResponder.insertNewline(_:)))
        expect(c.filterInput.committed == ["#type app"] && c.queryText.isEmpty, "Enter で #type app のチップ \(c.filterInput.committed) 「\(c.queryText)」")
        expect(focused(c), "Enter の後も入力欄が first responder")
        type(c, "sa")
        expect(c.queryText == "sa" && c.filterInput.currentQuery == "#type app sa", "続けて打てる「\(c.queryText)」→ \(c.filterInput.currentQuery)")

        // 2) 一覧の行を押して決める（フォーカスを外してから）
        c = make()
        type(c, "#t ")
        c.panel.makeFirstResponder(nil)
        c.filterInput.acceptRow(c.filterInput.palette.map { c.filterInput.displayed($0).firstIndex { $0.insert == "app" } ?? 0 } ?? 0)
        expect(c.filterInput.committed == ["#type app"], "行を押して決める \(c.filterInput.committed)")
        expect(focused(c), "行を押した後も入力欄が first responder")
        type(c, "s")
        expect(c.queryText == "s", "行を押した後に打てる「\(c.queryText)」")

        // 3) 「#t #app」と打つ（前の版の名前）→ 空白でチップ → 続けて打てる
        c = make()
        type(c, "#t #ap")
        expect(c.filterInput.palette?.mode == .values(.type), "「#t #ap」は #type の値の候補")
        type(c, "p ")
        expect(c.filterInput.committed == ["#type app"] && c.queryText.isEmpty, "「#t #app 」→ #type app \(c.filterInput.committed) 「\(c.queryText)」")
        type(c, "sa")
        expect(c.queryText == "sa" && focused(c), "「#t #app」の後に打てる「\(c.queryText)」")

        // 4) 「#t #ap」で Tab → 一覧の先頭が決まる
        c = make()
        type(c, "#t #ap")
        key(c, #selector(NSResponder.insertTab(_:)))
        expect(c.filterInput.committed == ["#type app"] && focused(c), "「#t #ap」で Tab → \(c.filterInput.committed)")
        type(c, "x")
        expect(c.queryText == "x", "Tab の後に打てる")

        // 5) 次のコマンドの札を押す・Backspace でチップを消す
        c = make()
        c.panel.makeFirstResponder(nil)
        c.filterInput.acceptNext("#kind ss")
        expect(focused(c), "札を押した後も入力欄が first responder")
        key(c, #selector(NSResponder.deleteBackward(_:)))
        expect(c.filterInput.committed.isEmpty && c.queryText == "#kind " && c.filterInput.palette?.mode == .values(.kind) && focused(c),
               "Backspace で #kind の値の一覧に戻る「\(c.queryText)」")
        key(c, #selector(NSResponder.deleteBackward(_:)))
        expect(c.queryText.isEmpty && c.filterInput.palette == nil, "もう一度でコマンドも消える「\(c.queryText)」")
        type(c, "y")
        expect(c.queryText == "y", "戻した後に打てる「\(c.queryText)」")

        // 5b) #を繋げたとき: ← / Backspace を押すたびに 1 つ前のコマンドの値の一覧へ戻る
        c = make()
        type(c, "#date 7d "); type(c, "#type app ")
        expect(c.filterInput.committed == ["#date 7d", "#type app"] && c.queryText.isEmpty, "2 つのチップ \(c.filterInput.committed)")
        key(c, #selector(NSResponder.moveLeft(_:)))
        expect(c.filterInput.committed == ["#date 7d"] && c.queryText == "#type " && c.filterInput.palette?.mode == .values(.type), "1 回戻ると #type の一覧「\(c.queryText)」")
        key(c, #selector(NSResponder.deleteBackward(_:)))
        expect(c.filterInput.committed.isEmpty && c.queryText == "#date " && c.filterInput.palette?.mode == .values(.date), "2 回戻ると #date の一覧「\(c.queryText)」")
        key(c, #selector(NSResponder.moveLeft(_:)))
        expect(c.queryText.isEmpty && c.filterInput.palette == nil && focused(c), "3 回で何も無い入力欄")
        // 打っていた言葉は残す。打ち直したらふつうの Backspace
        c = make()
        type(c, "#date 7d "); type(c, "請求")
        tv(c)?.setSelectedRange(NSRange(location: 0, length: 0))
        key(c, #selector(NSResponder.deleteBackward(_:)))
        expect(c.filterInput.committed.isEmpty && c.queryText == "請求 #date " && c.filterInput.palette?.mode == .values(.date), "言葉を残して #date の一覧「\(c.queryText)」")
        type(c, "t")
        key(c, #selector(NSResponder.deleteBackward(_:)))
        expect(c.queryText == "請求 #date ", "触った後の Backspace は 1 文字消す「\(c.queryText)」")

        // 5d) ヒントが空・「　」で始まる行でも落ちない（クリップボードの行で落ちた）
        for h in ["", "　", "　↩ 貼る", "↩  開く"] { ResultRow().setHint(h) }
        expect(true, "空のヒントでも落ちない")

        // 6) 候補が多いとき: 行は一度に全部作らず、↓ で選ぶとスクロールする
        c = make()
        type(c, "#type app ")
        let many = (0..<1500).map { RowItem(title: "見本アプリ \($0)", sub: "/Applications/見本\($0).app", iconImage: NSImage(), hint: RowItem.appHint) }
        c.setResults([ResultSection(title: "アプリ", symbol: "app.badge", items: many)], query: c.filterInput.currentQuery)
        expect(c.resultCount == 1500 && c.builtRowCount <= SearchPanelController.rowBatch, "1500 件で作った行は \(c.builtRowCount)")
        expect(c.panel.frame.height > 600, "候補が多いとパネルが伸びる")
        expect(c.panel.frame.height <= SearchPanelController.maxPanelHeight + 1, "パネルの高さ \(Int(c.panel.frame.height)) は上限 \(Int(SearchPanelController.maxPanelHeight)) まで")
        for _ in 0..<30 { key(c, #selector(NSResponder.moveDown(_:))) }
        expect(c.selectedRow == 30 && c.scrollOffset > 0, "↓ 30 回で選択 \(c.selectedRow)・スクロール \(Int(c.scrollOffset))")
        for _ in 0..<300 { key(c, #selector(NSResponder.moveDown(_:))) }
        expect(c.selectedRow == 330 && c.builtRowCount > 330, "↓ 330 回で行を足す（作った行 \(c.builtRowCount)）")
        expect(focused(c), "一覧を動かしても入力欄が first responder")
        // 同じ入力の結果が後から届き直しても（件数が多いと少しずつ届く）、選んでいた物から動かない
        let off = c.scrollOffset
        c.setResults([ResultSection(title: "アプリ", symbol: "app.badge", items: many)], query: c.filterInput.currentQuery)
        expect(c.selectedRow == 330 && abs(c.scrollOffset - off) < 1, "届き直しで選択 \(c.selectedRow)・スクロール \(Int(off)) → \(Int(c.scrollOffset))")
        let more = (0..<10).map { RowItem(title: "後から来た \($0)", sub: "/Applications/後\($0).app", iconImage: NSImage(), hint: RowItem.appHint) } + many
        c.setResults([ResultSection(title: "アプリ", symbol: "app.badge", items: more)], query: c.filterInput.currentQuery)
        expect(c.selectedRow == 340, "前に 10 件増えても同じ物（見本アプリ 330）を選んだまま: \(c.selectedRow)")
        type(c, "x")
        c.setResults([ResultSection(title: "アプリ", symbol: "app.badge", items: many)], query: c.filterInput.currentQuery)
        expect(c.selectedRow == 0, "入力が変わったら先頭から: \(c.selectedRow)")

        // 7) 「#」を打たない言葉からの候補: Tab でチップにして言葉を外す
        c = make()
        type(c, "先週の請求書")
        expect(c.filterInput.suggestions.first?.title == "#date lastweek", "「先週の請求書」で #date lastweek の候補 \(c.filterInput.suggestions.map(\.title))")
        expect(c.filterInput.committed.isEmpty, "候補を出すだけでチップにはしない")
        key(c, #selector(NSResponder.insertTab(_:)))
        expect(c.filterInput.committed == ["#date lastweek"] && c.queryText == "請求書" && focused(c), "Tab で決める → \(c.filterInput.committed)「\(c.queryText)」")
        c = make()
        type(c, "画像")
        key(c, #selector(NSResponder.moveRight(_:)))
        expect(c.filterInput.committed == ["#kind image"] && c.queryText.isEmpty, "→ でも決める \(c.filterInput.committed)")
        c = make()
        type(c, "見積書")
        key(c, #selector(NSResponder.insertTab(_:)))
        expect(c.filterInput.committed.isEmpty && c.queryText == "見積書" && focused(c), "候補が無いときの Tab は何もしない（入力欄のまま）")

        // 8) よく使う組み合わせを Enter でまとめてチップに
        c = make()
        var mem = FilterMemory()
        mem.combos = FilterMemory.build(from: (0..<3).map { _ in
            var e = SearchLogEntry(ts: Int(Date().timeIntervalSince1970), query: "#ext pdf #path Downloads", edits: [], candidates: [],
                                   dismissed: false, notFound: false, ms: 1)
            e.chosenRank = 1
            return e
        }).combos
        c.filterInput.memory = { mem }
        type(c, "#")
        key(c, #selector(NSResponder.insertNewline(_:)))
        expect(c.filterInput.committed == ["#ext pdf", "#path Downloads"] && focused(c), "「#」→ Enter で組み合わせ \(c.filterInput.committed)")
        key(c, #selector(NSResponder.deleteToBeginningOfLine(_:)))
        expect(c.filterInput.committed.isEmpty, "⌘⌫ でチップを全部消す")
        c.filterInput.acceptNext("#ext pdf"); c.filterInput.acceptNext("#date 7d")
        c.filterInput.removeChip(.ext)
        expect(c.filterInput.committed == ["#date 7d"] && focused(c), "チップの × でその条件だけ消す \(c.filterInput.committed)")

        // 9) ⌘S（#保存）で名前を付けて保存 → #名前 で呼び出す
        c = make()
        var saved: SavedFilter?
        c.filterInput.onSave = { saved = $0; return false }
        c.filterInput.acceptNext("#ext md")
        c.filterInput.beginSave()
        expect(c.queryText == "#保存 " && c.filterInput.palette?.mode == .save, "⌘S で「#保存 」")
        type(c, "週報")
        key(c, #selector(NSResponder.insertNewline(_:)))
        expect(saved == SavedFilter(name: "週報", commands: ["#ext md"]) && c.queryText.isEmpty, "Enter で保存 \(String(describing: saved))")
        expect(c.filterInput.notice?.contains("保存しました") == true && c.filterInput.committed == ["#ext md"], "保存した後もチップはそのまま「\(c.filterInput.notice ?? "")」")
        SavedFilters.set([saved!])
        c = make()
        type(c, "#週報 ")
        expect(c.filterInput.committed == ["#ext md"] && c.queryText.isEmpty, "#週報 で呼び出す \(c.filterInput.committed)")
        SavedFilters.set([])

        // 10) #alias: 言い方 → 行き先を選ぶ状態 → Enter で辞書に足して元に戻る
        let target = Candidate.file(FileResult(file: FileEntry(path: NSHomeDirectory() + "/Desktop/見本.png"), score: 1))
        c = make()
        var added: [DictEntry] = []
        var replaceNext = false
        c.filterInput.onAddDictionary = { added.append($0); return replaceNext }
        c.filterInput.acceptNext("#kind ss")
        type(c, "メモ #alias 黒い画面")
        expect(c.filterInput.palette?.mode == .alias, "「#alias 黒い画面」で辞書に足す一覧")
        key(c, #selector(NSResponder.insertNewline(_:)))
        expect(c.filterInput.isPickingAlias && c.queryText.isEmpty && c.filterInput.committed.isEmpty, "Enter で行き先を選ぶ状態")
        expect(c.filterInput.currentQuery == "黒い画面" && focused(c), "最初は言い方そのもので探す「\(c.filterInput.currentQuery)」")
        type(c, "見本")
        expect(c.filterInput.currentQuery == "見本", "打つと名前で絞る")
        c.setResults([ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: [RowItem(target)])], query: c.filterInput.currentQuery)
        key(c, #selector(NSResponder.insertNewline(_:)))
        expect(added.last?.phrase == "黒い画面" && added.last?.target == .file && added.last?.key.hasSuffix("/Desktop/見本.png") == true, "Enter で辞書に足す \(added.map(\.phrase))")
        expect(!c.filterInput.isPickingAlias && c.filterInput.committed == ["#kind ss"] && c.queryText == "メモ ", "元の入力欄に戻る \(c.filterInput.committed)「\(c.queryText)」")
        expect(c.filterInput.notice == "黒い画面 → 見本.png を足しました" && focused(c), "「足しました」と出す「\(c.filterInput.notice ?? "")」")
        // 取りやめ
        c = make()
        type(c, "#alias ねこ")
        key(c, #selector(NSResponder.insertNewline(_:)))
        let n0 = added.count
        key(c, #selector(NSResponder.cancelOperation(_:)))
        expect(!c.filterInput.isPickingAlias, "Esc で取りやめ")
        expect(added.count == n0 && c.queryText.isEmpty && focused(c), "取りやめたら辞書は変えない")
        // 上書き
        c = make()
        c.filterInput.onAddDictionary = { added.append($0); return replaceNext }
        replaceNext = true
        type(c, "#alias 黒い画面")
        key(c, #selector(NSResponder.insertNewline(_:)))
        c.setResults([ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: [RowItem(target)])], query: c.filterInput.currentQuery)
        key(c, #selector(NSResponder.insertNewline(_:)))
        expect(c.filterInput.notice?.hasSuffix("置き換えました") == true, "同じ言い方は置き換えたと出す「\(c.filterInput.notice ?? "")」")
        replaceNext = false

        // 11) ⌥Enter: 今の言葉 → 選んだ物を辞書に足す
        c = make()
        c.filterInput.onAddDictionary = { added.append($0); return false }
        var opened = false
        c.onOpen = { _, _, _ in opened = true }
        type(c, "ねこの写真")
        c.setResults([ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: [RowItem(target)])], query: c.filterInput.currentQuery)
        key(c, #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        expect(added.last?.phrase == "ねこの写真" && opened, "⌥Enter で辞書に足して開く \(added.last?.phrase ?? "")")

        // 12) 辞書に当たった物は候補の先頭の「辞書」の節
        c = make()
        c.dictionaryCandidates = { q in q.contains("黒い画面") ? [target] : [] }
        type(c, "黒い画面")
        let other = Candidate.file(FileResult(file: FileEntry(path: NSHomeDirectory() + "/Desktop/別.png"), score: 1))
        c.setResults([ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: [RowItem(other), RowItem(target)])], query: c.filterInput.currentQuery)
        expect(c.resultCount == 2 && c.firstResultPath == target.path, "辞書の物を先頭に、下の節からは外す（\(c.resultCount) 件）")

        // 13) ファイルの行があるときだけパネルを右に広げてプレビューを出す（設定で切れる。行を動かしても入力欄のまま）
        if SearchPanelController.screenFitsPreview {
            c = make()
            type(c, "見本")
            let appItem = RowItem(title: "見本アプリ", sub: "/Applications/見本.app", iconImage: NSImage(), hint: RowItem.appHint)
            c.setResults([ResultSection(title: "アプリ", symbol: "app.badge", items: [appItem])], query: c.filterInput.currentQuery)
            let narrow = c.panel.frame.width
            expect(!c.wide && narrow == SearchPanelController.width, "アプリだけのときは広げない（幅 \(Int(narrow))）")
            c.setResults([ResultSection(title: "アプリ", symbol: "app.badge", items: [appItem]),
                          ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: [RowItem(target), RowItem(other)])],
                         query: c.filterInput.currentQuery)
            expect(!c.wide && c.panel.frame.width == SearchPanelController.width,
                   "アプリの行を選んでいる間は広げない（幅 \(Int(c.panel.frame.width))）")
            key(c, #selector(NSResponder.moveDown(_:)))
            expect(c.wide && c.panel.frame.width == SearchPanelController.width + FilePreviewPane.width,
                   "ファイルの行を選ぶと右に広げる（幅 \(Int(c.panel.frame.width))）")
            expect(c.panel.frame.height >= SearchPanelController.fieldHeight + SearchPanelController.previewMinHeight,
                   "プレビューが読める高さ（\(Int(c.panel.frame.height))）")
            let t0 = c.preview.currentToken
            key(c, #selector(NSResponder.moveDown(_:)))
            expect(c.selectedRow == 2 && c.preview.currentToken > t0 && focused(c), "↓ でプレビューを替えても入力欄のまま")
            type(c, "z")
            expect(c.queryText == "見本z", "プレビューを出した後も打てる「\(c.queryText)」")
            SearchPanelController.previewEnabled = false
            c.setResults([ResultSection(title: "ファイル・フォルダ", symbol: "folder", items: [RowItem(target)])], query: c.filterInput.currentQuery)
            expect(!c.wide && c.panel.frame.width == SearchPanelController.width, "設定を切ると広げない")
            SearchPanelController.previewEnabled = true
        }

        // 14) クリップボードの履歴: 「#clip 」で切り替え、打った言葉で絞る、空の ⌫ で戻る、Esc は言葉を消してから閉じる
        c = make()
        var asked: [String] = []
        c.onQuery = { asked.append($0) }
        type(c, "#cl")
        expect(c.filterInput.palette?.items.contains { $0.insert == "#clip" } == true && !c.filterInput.clipMode, "「#cl」で一覧に #clip")
        type(c, "ip ")
        expect(c.filterInput.clipMode && c.queryText.isEmpty && c.filterInput.palette == nil, "「#clip 」で履歴の状態「\(c.queryText)」")
        type(c, "請求")
        expect(c.filterInput.currentQuery == "#clip 請求" && asked.last == "#clip 請求" && focused(c), "打った言葉で履歴を探す \(asked.last ?? "")")
        let clip = ClipItem(id: 1, text: "請求書\nNo.123", source: .init(bundleID: "com.apple.Safari", app: "Safari", title: "見積もり", at: Date()),
                            count: 1, pastes: [.init(bundleID: "com.apple.mail", app: "メール", title: "", at: Date())])
        c.setResults([ResultSection(title: "クリップボード", symbol: "doc.on.clipboard", items: [RowItem(.clip(clip))])], query: c.filterInput.currentQuery)
        expect(c.resultCount == 1, "履歴の行")
        let row = RowItem(.clip(clip))
        expect(row.title == "請求書 No.123" && row.sub.contains("Safari「見積もり」") && row.sub.contains("→ メール"),
               "行にコピー元と貼った先「\(row.sub)」")
        if SearchPanelController.screenFitsPreview { expect(c.wide, "履歴の行は右に全文を出す") }
        expect(c.filterInput.addToDictionary(.clip(clip)) == nil, "履歴の行は辞書に足さない")
        key(c, #selector(NSResponder.cancelOperation(_:)))
        expect(c.filterInput.clipMode && c.queryText.isEmpty, "Esc はまず言葉を消す")
        key(c, #selector(NSResponder.deleteBackward(_:)))
        expect(!c.filterInput.clipMode && c.queryText.isEmpty && focused(c), "空の ⌫ でふつうの入力欄に戻る")
        c = make()
        c.filterInput.beginClip()
        expect(c.filterInput.clipMode && c.filterInput.currentQuery == "#clip " && focused(c), "専用のキーの入口（beginClip）")
        // 履歴を #date・#from・#to で絞る: 「#」でコマンドの一覧、値は件数つき、Tab で決めると入力欄の文字になる
        let cnow = Date()
        let sample = [
            ClipItem(id: 1, text: "請求書 No.123", source: .init(bundleID: "com.apple.Safari", app: "Safari", title: "", at: cnow), count: 1,
                     pastes: [.init(bundleID: "com.apple.mail", app: "メール", title: "", at: cnow)]),
            ClipItem(id: 2, text: "ねこ", source: .init(bundleID: "com.apple.Notes", app: "メモ", title: "", at: cnow.addingTimeInterval(-86400 * 3)), count: 1, pastes: []),
        ]
        c.filterInput.clips = { sample }
        type(c, "#fr")
        expect(c.filterInput.palette?.mode == .clipCommands && c.resultCount == 1, "履歴で「#fr」→ #from の一覧（\(c.resultCount) 行）")
        key(c, #selector(NSResponder.insertTab(_:)))
        expect(c.queryText == "#from " && c.filterInput.palette?.mode == .clipValues("from"), "Tab で「#from 」→ アプリの一覧「\(c.queryText)」")
        key(c, #selector(NSResponder.insertTab(_:)))
        expect(c.queryText == "#from Safari " && c.filterInput.palette == nil && c.filterInput.clipMode, "Tab で「#from Safari 」「\(c.queryText)」")
        expect(c.filterInput.currentQuery == "#clip #from Safari" && focused(c), "検索は「\(c.filterInput.currentQuery)」")
        // ファイルの検索で付けていた #date は履歴にも持ち越す
        c = make()
        c.filterInput.clips = { sample }
        type(c, "#date 7d ")
        c.filterInput.beginClip()
        expect(c.queryText == "#date 7d" && c.filterInput.committed.isEmpty, "#date のチップを履歴に持ち越す「\(c.queryText)」")

        print("確かめ \(checks - fails)/\(checks)")
        return fails == 0
    }
}
