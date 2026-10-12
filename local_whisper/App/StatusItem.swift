import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusItem: NSObject {
    private let coordinator: AppCoordinator
    private let statusItem: NSStatusItem
    private var menuState: String?
    private var settingsWindow: NSWindow?
    private var planPreviewWindow: NSWindow?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.settingsWindow = nil
        super.init()

        coordinator.openSettings = { [weak self] in
            self?.openSettings()
        }
        coordinator.openPlanPreview = { [weak self] in
            self?.openPlanPreview()
        }

        let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "local_whisper")
        image?.isTemplate = true
        statusItem.button?.image = image

        observe()
    }

    private func observe() {
        withObservationTracking {
            applyRemaining(coordinator.countdown.remainingLabel)
            rebuildMenuIfNeeded(
                timerRunning: coordinator.countdown.isRunning,
                browserState: String(describing: coordinator.browser.state),
                hasPlanPreview: coordinator.planPreview != nil
            )
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

    private func rebuildMenuIfNeeded(timerRunning: Bool, browserState: String, hasPlanPreview: Bool) {
        let state = "\(timerRunning)-\(browserState)-\(hasPlanPreview)"
        guard menuState != state else { return }
        menuState = state

        let menu = NSMenu()
        menu.addItem(menuItem("Show Encouragement", key: "e", action: #selector(showEncouragement)))
        menu.addItem(menuItem("Transcribe", key: "w", action: #selector(transcribe)))
        menu.addItem(menuItem("Read screenshot", key: "r", action: #selector(readScreenshot)))
        menu.addItem(menuItem("Browse web", key: nil, action: #selector(browseWeb)))
        if hasPlanPreview {
            menu.addItem(menuItem("Preview Plan", key: nil, action: #selector(openPlanPreview)))
        }
        if timerRunning {
            menu.addItem(menuItem("Cancel Timer", key: nil, action: #selector(cancelTimer)))
        } else {
            menu.addItem(menuItem("Start Timer", key: "t", action: #selector(startTimer)))
        }
        if coordinator.browser.state == .running {
            menu.addItem(menuItem("Pause Browser", key: nil, action: #selector(pauseBrowser)))
        } else if coordinator.browser.state == .pausedForUser {
            menu.addItem(menuItem("Resume Browser", key: nil, action: #selector(resumeBrowser)))
        }
        if coordinator.browser.isActive {
            menu.addItem(menuItem("Stop Browser", key: nil, action: #selector(stopBrowser)))
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

    @objc private func browseWeb() {
        coordinator.browseWeb()
    }

    @objc private func openPlanPreview() {
        guard let plan = coordinator.planPreview else { return }
        if planPreviewWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Preview Plan"
            window.isReleasedWhenClosed = false
            window.center()
            planPreviewWindow = window
        }

        planPreviewWindow?.contentView = NSHostingView(
            rootView: BrowserPlanPreview(goal: plan.goal, code: plan.code)
        )
        guard let planPreviewWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        planPreviewWindow.collectionBehavior.insert(.moveToActiveSpace)
        planPreviewWindow.makeKeyAndOrderFront(nil)
    }

    @objc private func pauseBrowser() {
        coordinator.browser.pause()
    }

    @objc private func resumeBrowser() {
        coordinator.browser.resume()
    }

    @objc private func stopBrowser() {
        coordinator.browser.stop()
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
