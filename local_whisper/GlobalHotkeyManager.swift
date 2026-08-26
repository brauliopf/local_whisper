import AppKit
import Carbon

/// System-wide Carbon hotkeys — does not need Accessibility.
final class GlobalHotkeyManager {
    var onEncouragement: (() -> Void)?
    var onTranscribe: (() -> Void)?
    var onEscape: (() -> Void)?

    private var encouragementHotKeyRef: EventHotKeyRef?
    private var transcribeHotKeyRef: EventHotKeyRef?
    private var escapeHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private static let signature: OSType = 0x4C574850 // 'LWHP'
    private static let encouragementID = EventHotKeyID(signature: signature, id: 1)
    private static let transcribeID = EventHotKeyID(signature: signature, id: 2)
    private static let escapeID = EventHotKeyID(signature: signature, id: 3)

    struct Registration {
        var encouragement = false
        var transcribe = false
    }

    func start() -> Registration {
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
                guard status == noErr else { return OSStatus(eventNotHandledErr) }

                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    switch hotKeyID.id {
                    case 1: manager.onEncouragement?()
                    case 2: manager.onTranscribe?()
                    case 3: manager.onEscape?()
                    default: break
                    }
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        guard installed == noErr else { return Registration() }

        var result = Registration()
        result.encouragement = RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            UInt32(controlKey | optionKey),
            Self.encouragementID,
            GetApplicationEventTarget(),
            0,
            &encouragementHotKeyRef
        ) == noErr
        result.transcribe = RegisterEventHotKey(
            UInt32(kVK_ANSI_W),
            UInt32(controlKey | optionKey),
            Self.transcribeID,
            GetApplicationEventTarget(),
            0,
            &transcribeHotKeyRef
        ) == noErr
        return result
    }

    func setEscapeEnabled(_ enabled: Bool) {
        if let escapeHotKeyRef {
            UnregisterEventHotKey(escapeHotKeyRef)
            self.escapeHotKeyRef = nil
        }

        guard enabled else { return }

        _ = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            Self.escapeID,
            GetApplicationEventTarget(),
            0,
            &escapeHotKeyRef
        )
    }

    func stop() {
        setEscapeEnabled(false)
        if let encouragementHotKeyRef {
            UnregisterEventHotKey(encouragementHotKeyRef)
        }
        if let transcribeHotKeyRef {
            UnregisterEventHotKey(transcribeHotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        encouragementHotKeyRef = nil
        transcribeHotKeyRef = nil
        eventHandler = nil
    }

    deinit {
        stop()
    }
}
