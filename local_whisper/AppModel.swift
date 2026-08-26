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
    private var didFinishLaunching = false

    init() {
        hotkeyManager.onTrigger = { [weak self] in
            self?.showEncouragement()
        }
    }

    func finishLaunching() {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true

        if !hotkeyManager.start() {
            toastController.show(
                message: "Couldn't register ⌃⌥E — another app may already use that shortcut.",
                isError: true
            )
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
