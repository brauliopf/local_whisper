import AppKit
import Observation

@MainActor
final class StatusItem: NSObject {
    private let coordinator: AppCoordinator
    private let item: NSStatusItem
    private var menuShowsRunning: Bool?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        coordinator.openSettings = { [weak self] in
            self?.openSettings()
        }

        let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "local_whisper")
        image?.isTemplate = true
        item.button?.image = image

        observe()
    }

    private func observe() {
        withObservationTracking {
            applyRemaining(coordinator.countdown.remainingLabel)
            rebuildMenuIfNeeded(isRunning: coordinator.countdown.isRunning)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
            }
        }
    }

    private func applyRemaining(_ remaining: String?) {
        guard let button = item.button else { return }
        if let remaining {
            item.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeft
            button.attributedTitle = NSAttributedString(
                string: remaining,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: NSFont.systemFontSize,
                        weight: .regular
                    )
                ]
            )
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
            button.imagePosition = .imageOnly
            item.length = NSStatusItem.squareLength
        }
    }

    private func rebuildMenuIfNeeded(isRunning: Bool) {
        guard menuShowsRunning != isRunning else { return }
        menuShowsRunning = isRunning

        let menu = NSMenu()
        menu.addItem(item("Show Encouragement", key: "e", action: #selector(showEncouragement)))
        menu.addItem(item("Transcribe", key: "w", action: #selector(transcribe)))
        menu.addItem(item("Read screenshot", key: "r", action: #selector(readScreenshot)))
        if isRunning {
            menu.addItem(item("Cancel Timer", key: nil, action: #selector(cancelTimer)))
        } else {
            menu.addItem(item("Start Timer", key: "t", action: #selector(startTimer)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Settings…", key: nil, action: #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit", key: "q", modifiers: .command, action: #selector(quit)))
        self.item.menu = menu
    }

    private func item(
        _ title: String,
        key: String?,
        modifiers: NSEvent.ModifierFlags = [.control, .option],
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key ?? "")
        item.target = self
        if key != nil {
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }

    @objc private func showEncouragement() {
        coordinator.showEncouragement()
    }

    @objc private func transcribe() {
        coordinator.toggleTranscription()
    }

    @objc private func readScreenshot() {
        coordinator.readScreenshot()
    }

    @objc private func startTimer() {
        coordinator.countdown.start()
    }

    @objc private func cancelTimer() {
        coordinator.countdown.cancel()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
