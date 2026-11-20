import AppKit
import Carbon
import RaidenCore

/// ホットキーの名前と、システムのショートカットとの重なりを調べる
enum HotKeyInfo {
    static let defaultKey = RaidenSettings.HotKeySetting(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), label: "⌥Space")
    static let fallbackKey = RaidenSettings.HotKeySetting(keyCode: UInt32(kVK_Space),
                                                          modifiers: UInt32(controlKey | optionKey | cmdKey), label: "⌃⌥⌘Space")
    /// クリップボードの履歴を開くキー（⌥V。取れなければ ⌃⌥V）
    static let clipDefaultKey = RaidenSettings.HotKeySetting(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey), label: "⌥V")
    static let clipFallbackKey = RaidenSettings.HotKeySetting(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥V")

    /// 今の入力欄を開くキー（設定が無ければ初期値）
    static func currentMain(_ host: SettingsHost) -> RaidenSettings.HotKeySetting { host.settings.hotKey ?? defaultKey }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func label(keyCode: UInt32, modifiers m: UInt32, chars: String?) -> String {
        var s = ""
        if m & UInt32(controlKey) != 0 { s += "⌃" }
        if m & UInt32(optionKey) != 0 { s += "⌥" }
        if m & UInt32(shiftKey) != 0 { s += "⇧" }
        if m & UInt32(cmdKey) != 0 { s += "⌘" }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let n = names[Int(keyCode)] { return s + n }
        return s + (chars?.uppercased() ?? "?")
    }

    /// システムのショートカット（システム設定 → キーボード → ショートカット。Spotlight・入力ソースなど）と重なるか
    static func conflictsWithSystem(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var ref: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&ref) == noErr, let arr = ref?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        for d in arr {
            guard (d[kHISymbolicHotKeyEnabled as String] as? Bool) ?? false,
                  let code = (d[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let mods = (d[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { continue }
            if code == keyCode && (mods & mask) == (modifiers & mask) { return true }
        }
        return false
    }
}

/// 押して登録するホットキーの欄。クリックしてからキーを押すと onRecord を呼ぶ。Esc でやめる
final class HotKeyRecorder: NSView {
    var label: String { didSet { needsDisplay = true } }
    var onRecord: ((RaidenSettings.HotKeySetting) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    private(set) var recording = false { didSet { needsDisplay = true } }

    init(label: String) {
        self.label = label
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
        onBegin?()
    }
    override func resignFirstResponder() -> Bool {
        if recording { recording = false; onEnd?() }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == UInt16(kVK_Escape) { stop(); return }
        let m = HotKeyInfo.carbonModifiers(event.modifierFlags)
        let isF = (Int(kVK_F1)...Int(kVK_F12)).contains(Int(event.keyCode))
        // 修飾キー（⌘⌥⌃）の無いキーは、文字入力とぶつかるので受けない（F キーは可）
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 || isF else { NSSound.beep(); return }
        let code = UInt32(event.keyCode)
        let hk = RaidenSettings.HotKeySetting(keyCode: code, modifiers: m,
                                              label: HotKeyInfo.label(keyCode: code, modifiers: m, chars: event.charactersIgnoringModifiers))
        stop()
        onRecord?(hk)
    }

    private func stop() {
        recording = false
        window?.makeFirstResponder(nil)
        onEnd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        (recording ? SettingsStyle.selection : NSColor(white: 1, alpha: 0.9)).setFill()
        let p = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        p.fill()
        (recording ? SettingsStyle.accent.withAlphaComponent(0.6) : NSColor(white: 0, alpha: 0.15)).setStroke()
        p.lineWidth = 1
        p.stroke()
        let s = recording ? "キーを押してください…" : label
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: recording ? 12 : 13, weight: .medium),
            .foregroundColor: recording ? SettingsStyle.accent : SettingsStyle.text,
        ]
        let size = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
