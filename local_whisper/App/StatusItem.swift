import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusItem: NSObject {
    private let coordinator: AppCoordinator
    private let statusItem: NSStatusItem
    private var menuShowsRunning: Bool?
    private var settingsWindow: NSWindow?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.settingsWindow = nil
        super.init()

        coordinator.openSettings = { [weak self] in
            self?.openSettings()
        }

        let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "local_whisper")
        image?.isTemplate = true
        statusItem.button?.image = image

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
        guard let button = statusItem.button else { return }
        if let remaining {
            statusItem.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeft
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = remaining
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            statusItem.length = NSStatusItem.squareLength
        }
    }

    private func rebuildMenuIfNeeded(isRunning: Bool) {
        guard menuShowsRunning != isRunning else { return }
        menuShowsRunning = isRunning

        let menu = NSMenu()
        menu.addItem(menuItem("Show Encouragement", key: "e", action: #selector(showEncouragement)))
        menu.addItem(menuItem("Transcribe", key: "w", action: #selector(transcribe)))
        menu.addItem(menuItem("Read screenshot", key: "r", action: #selector(readScreenshot)))
        if isRunning {
            menu.addItem(menuItem("Cancel Timer", key: nil, action: #selector(cancelTimer)))
        } else {
            menu.addItem(menuItem("Start Timer", key: "t", action: #selector(startTimer)))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", key: nil, action: #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit", key: "q", modifiers: .command, action: #selector(quit)))
        statusItem.menu = menu
    }

    private func menuItem(
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
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            let hostingView = NSHostingView(rootView: SettingsView())
            hostingView.frame = window.contentView?.bounds ?? .zero
            hostingView.autoresizingMask = [.width, .height]
            window.contentView = hostingView
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }

        guard let settingsWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.collectionBehavior.insert(.moveToActiveSpace)
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
