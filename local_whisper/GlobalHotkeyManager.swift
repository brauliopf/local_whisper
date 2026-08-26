import AppKit
import Carbon

/// System-wide ⌃⌥E via Carbon hotkeys — does not need Accessibility.
final class GlobalHotkeyManager {
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private static let hotKeyID = EventHotKeyID(signature: 0x4C574850, id: 1) // 'LWHP'

    func start() -> Bool {
        stop()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }

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
                guard status == noErr, hotKeyID.id == GlobalHotkeyManager.hotKeyID.id else {
                    return OSStatus(eventNotHandledErr)
                }

                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.onTrigger?()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        guard installed == noErr else { return false }

        let registered = RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            UInt32(controlKey | optionKey),
            Self.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        return registered == noErr
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        hotKeyRef = nil
        eventHandler = nil
    }

    deinit {
        stop()
    }
}
