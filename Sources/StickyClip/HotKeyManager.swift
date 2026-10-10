import Cocoa
import Carbon

/// Registers the global ⇧⌘V shortcut via the Carbon hot-key API
/// (works without Accessibility permission).
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onShowNotes: (() -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    /// Returns false if the shortcut could not be registered (e.g. another app owns it).
    @discardableResult
    func register() -> Bool {
        unregisterAll()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
            guard let eventRef else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr {
                let id = hotKeyID.id
                DispatchQueue.main.async {
                    HotKeyManager.shared.handleHotKey(id: id)
                }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &eventHandlerRef)

        // ⇧⌘V
        return registerKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(shiftKey | cmdKey), id: 1)
    }

    private func registerKey(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5354_434C), id: id) // 'STCL'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRefs.append(ref)
            return true
        }
        NSLog("StickyClip: failed to register hot key (status \(status))")
        return false
    }

    private func handleHotKey(id: UInt32) {
        if id == 1 { onShowNotes?() }
    }

    func unregisterAll() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }
}
