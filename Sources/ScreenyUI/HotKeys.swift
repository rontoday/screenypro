import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon `RegisterEventHotKey`. Needs no accessibility permission.
/// Handlers run on the main thread.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    enum Key: UInt32 {
        case toggleRecording = 1
        case togglePause = 2
        case cancelCountdown = 3
    }

    private static let signature: OSType = 0x5343_5250 // 'SCRP'
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    /// Returns false when the combination is taken by another app or the system.
    @discardableResult
    func register(_ key: Key, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(key)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: key.rawValue)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("ScreenyPro: could not register hotkey \(key) (status \(status))")
            return false
        }
        refs[key.rawValue] = ref
        handlers[key.rawValue] = handler
        return true
    }

    func unregister(_ key: Key) {
        if let ref = refs.removeValue(forKey: key.rawValue) {
            UnregisterEventHotKey(ref)
        }
        handlers.removeValue(forKey: key.rawValue)
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventCallback, 1, &spec, nil, &eventHandler)
    }
}

private func hotKeyEventCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    // Carbon delivers hotkey events on the main thread.
    MainActor.assumeIsolated {
        HotKeyCenter.shared.fire(id)
    }
    return noErr
}
