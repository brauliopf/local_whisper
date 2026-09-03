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
            let root = await LocalTelemetry.shared.start(
                name: "user_operation",
                operation: "encouragement",
                trigger: "hotkey"
            )
            do {
                let childContext = await LocalTelemetry.shared.childContext(from: root)
                let message = try await TelemetryScope.$context.withValue(childContext) {
                    try await openAI.fetchEncouragement(apiKey: apiKey, model: ModelSettings.chat)
                }
                guard !Task.isCancelled else {
                    await LocalTelemetry.shared.finish(root, status: "cancelled")
                    return
                }
                await LocalTelemetry.shared.finish(root)
                toast.show(message: message, isError: false)
            } catch {
                await LocalTelemetry.shared.finish(
                    root,
                    status: Task.isCancelled ? "cancelled" : "error",
                    error: Task.isCancelled ? nil : error.localizedDescription
                )
                guard !Task.isCancelled else { return }
                toast.show(message: error.localizedDescription, isError: true)
            }
        }
    }
}
