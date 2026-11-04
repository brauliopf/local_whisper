import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusItem: NSObject {
    private let coordinator: AppCoordinator
    private let statusItem: NSStatusItem
    private var menuState: Bool?
    private var settingsWindow: NSWindow?
    private var chatWindow: NSWindow?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.settingsWindow = nil
        self.chatWindow = nil
        super.init()

        coordinator.openSettings = { [weak self] in
            self?.openSettings()
        }
        coordinator.openChat = { [weak self] in
            self?.openChat()
        }

        let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "local_whisper")
        image?.isTemplate = true
        statusItem.button?.image = image

        observe()
    }

    private func observe() {
        withObservationTracking {
            applyRemaining(coordinator.countdown.remainingLabel)
            rebuildMenuIfNeeded(timerRunning: coordinator.countdown.isRunning)
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

    private func rebuildMenuIfNeeded(timerRunning: Bool) {
        guard menuState != timerRunning else { return }
        menuState = timerRunning

        let menu = NSMenu()
        menu.addItem(menuItem("Show Encouragement", key: "e", action: #selector(showEncouragement)))
        menu.addItem(menuItem("Transcribe", key: "w", action: #selector(transcribe)))
        menu.addItem(menuItem("Voice Chat", key: "c", action: #selector(voiceChat)))
        menu.addItem(menuItem("Read screenshot", key: "r", action: #selector(readScreenshot)))
        if timerRunning {
            menu.addItem(menuItem("Cancel Timer", key: nil, action: #selector(cancelTimer)))
        } else {
            menu.addItem(menuItem("Start Timer", key: "t", action: #selector(startTimer)))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", key: "s", action: #selector(openSettings)))
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

    @objc private func voiceChat() {
        coordinator.toggleVoiceChat()
    }

    @objc private func startTimer() {
        coordinator.countdown.start()
    }

    @objc private func cancelTimer() {
        coordinator.countdown.cancel()
    }

    private func openChat() {
        if chatWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Voice Chat"
            let hostingView = NSHostingView(rootView: VoiceChatView(chat: coordinator.voiceChat))
            hostingView.frame = window.contentView?.bounds ?? .zero
            hostingView.autoresizingMask = [.width, .height]
            window.contentView = hostingView
            window.isReleasedWhenClosed = false
            window.center()
            chatWindow = window
        }

        guard let chatWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        chatWindow.collectionBehavior.insert(.moveToActiveSpace)
        chatWindow.makeKeyAndOrderFront(nil)
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
            let hostingView = NSHostingView(rootView: SettingsView(tokenState: coordinator.tokenState))
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
