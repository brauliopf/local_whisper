import Foundation

@MainActor
@Observable
final class Encouragement {
    var openSettings: (() -> Void)?

    private let backend: any BackendClienting
    private let keychain: any Keychaining
    private let toast: ToastPresenter
    private var task: Task<Void, Never>?

    init(
        backend: any BackendClienting,
        keychain: any Keychaining,
        toast: ToastPresenter
    ) {
        self.backend = backend
        self.keychain = keychain
        self.toast = toast
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func show() {
        guard let serviceToken = keychain.loadServiceToken(), !serviceToken.isEmpty else {
            openSettings?()
            return
        }

        cancel()
        toast.show(message: "Thinking…", isError: false)

        task = Task {
            await Telemetry.instrument(operation: "encouragement", trigger: "hotkey") {
                do {
                    let message = try await backend.fetchEncouragement(serviceToken: serviceToken)
                    guard !Task.isCancelled else { return }
                    toast.show(message: message, isError: false)
                } catch {
                    guard !Task.isCancelled else { return }
                    toast.show(message: error.localizedDescription, isError: true)
                    throw error
                }
            }
        }
    }
}
