import AppKit

final class GlobalHotkeyManager {
    var onTrigger: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() -> Bool {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard Self.matchesHotkey(event) else { return }
            Task { @MainActor in
                self?.onTrigger?()
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Self.matchesHotkey(event) {
                Task { @MainActor in
                    self.onTrigger?()
                }
                return nil
            }
            return event
        }

        return globalMonitor != nil
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private static func matchesHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        return flags == [.control, .option] && event.keyCode == 14
    }
}
