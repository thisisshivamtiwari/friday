import AppKit
import Carbon.HIToolbox

// MARK: - Hot Key Manager
/// Manages global keyboard shortcuts using Carbon's RegisterEventHotKey - still the
/// standard, permission-free way to do truly global hotkeys on macOS (works even when the
/// app isn't frontmost, no Accessibility/Input Monitoring prompt needed, unlike some
/// NSEvent global-monitor event types).
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandlerInstalled = false

    /// Registers a truly global hot key. `keyCode` is a Carbon/HIToolbox virtual key code
    /// (e.g. kVK_ANSI_A = 0x00, kVK_ANSI_P = 0x23).
    /// https://developer.apple.com/documentation/carbon/1443700-registereventhotkey
    func registerHotKey(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1
        handlers[id] = action

        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }

        let hotKeyID = EventHotKeyID(signature: OSType(0x464F4331), id: id) // 'FOC1'
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, carbonModifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        if status == noErr, let hotKeyRef {
            hotKeyRefs[id] = hotKeyRef
        } else {
            print("[HotKey] Failed to register hotkey (keyCode=\(keyCode)), status=\(status)")
        }
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                HotKeyManager.shared.handlers[id]?()
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
