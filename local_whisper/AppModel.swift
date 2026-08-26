import AppKit
import Foundation

@MainActor
@Observable
final class AppModel {
    var openSettings: (() -> Void)?

    private let toastController = ToastPanelController()
    private let openAIService = OpenAIService()
    private let hotkeyManager = GlobalHotkeyManager()
    private var fetchTask: Task<Void, Never>?
    private(set) var isGlobalHotkeyEnabled = false
    private var didFinishLaunching = false

    init() {
        hotkeyManager.onTrigger = { [weak self] in
            self?.showEncouragement()
        }
    }

    func finishLaunching() {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true

        isGlobalHotkeyEnabled = hotkeyManager.start()

        if !isGlobalHotkeyEnabled {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                toastController.show(
                    message: "Allow Accessibility access in System Settings for ⌃⌥E to work globally.",
                    isError: false
                )
            }
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func showEncouragement() {
        guard KeychainService.hasAPIKey else {
            openSettings?()
            return
        }

        fetchTask?.cancel()
        toastController.show(message: "Thinking…", isError: false)

        fetchTask = Task {
            do {
                let message = try await openAIService.fetchEncouragement()
                guard !Task.isCancelled else { return }
                toastController.show(message: message, isError: false)
            } catch {
                guard !Task.isCancelled else { return }
                toastController.show(message: error.localizedDescription, isError: true)
            }
        }
    }
}
