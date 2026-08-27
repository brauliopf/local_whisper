import Foundation

@MainActor
@Observable
final class Encouragement {
    var openSettings: (() -> Void)?

    private let openAI: any OpenAIClienting
    private let keychain: any Keychaining
    private let toast: ToastPresenter
    private var task: Task<Void, Never>?

    init(
        openAI: any OpenAIClienting,
        keychain: any Keychaining,
        toast: ToastPresenter
    ) {
        self.openAI = openAI
        self.keychain = keychain
        self.toast = toast
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func show() {
        guard let apiKey = keychain.loadAPIKey(), !apiKey.isEmpty else {
            openSettings?()
            return
        }

        cancel()
        toast.show(message: "Thinking…", isError: false)

        task = Task {
            do {
                let message = try await openAI.fetchEncouragement(apiKey: apiKey)
                guard !Task.isCancelled else { return }
                toast.show(message: message, isError: false)
            } catch {
                guard !Task.isCancelled else { return }
                toast.show(message: error.localizedDescription, isError: true)
            }
        }
    }
}
