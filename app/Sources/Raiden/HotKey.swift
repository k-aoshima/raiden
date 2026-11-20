import Carbon
import Foundation

/// Carbon の RegisterEventHotKey でグローバルなホットキーを登録する（アクセシビリティの許可は要らない）。
final class HotKey {
    private var ref: EventHotKeyRef?
    /// イベントの受け口はアプリで 1 つ（キーごとに付けると、キーが 2 つの時に 1 回押して 2 回動く）
    private static var handler: EventHandlerRef?
    private let action: () -> Void
    private static var all: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// 登録に失敗したら nil（ほかのアプリが同じキーを持っているなど）
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        id = HotKey.nextID
        HotKey.nextID += 1
        if HotKey.handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                if let k = HotKey.all[hk.id] { DispatchQueue.main.async { k.action() } }
                return noErr
            }, 1, &spec, nil, &HotKey.handler)
        }
        let hkID = EventHotKeyID(signature: OSType(0x5244_4E31), id: id)  // 'RDN1'
        let st = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if st != noErr || ref == nil { return nil }
        HotKey.all[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.all[id] = nil
    }
}
