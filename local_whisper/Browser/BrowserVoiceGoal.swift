import Foundation

@MainActor
final class BrowserVoiceGoal {
    var openSettings: (() -> Void)?
    var setEscapeEnabled: ((Bool) -> Void)?
    var onGoal: ((String) -> Void)?

    private let backend: any BackendClienting
    private let tokenState: ServiceTokenState
    private let toast: ToastPresenter
    private let capture: VoiceCapture
    private var transcriptionTask: Task<Void, Never>?

    init(
        backend: any BackendClienting,
        tokenState: ServiceTokenState,
        toast: ToastPresenter
    ) {
        self.backend = backend
        self.tokenState = tokenState
        self.toast = toast
        self.capture = VoiceCapture(toast: toast)
        capture.onRecordingStateChanged = { [weak self] recording in
            self?.setEscapeEnabled?(recording)
        }
        capture.onRecordingFinished = { [weak self] url in
            self?.transcribeGoal(url: url)
        }
    }

    var isRecording: Bool { capture.isRecording }

    func toggle() {
        capture.toggle(prompt: "Describe the browser task… press ⌃⌥A to stop")
    }

    func cancel(showToast: Bool = true) {
        capture.cancel(showToast: showToast)
    }

    func cancelInFlightWork() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }

    private func transcribeGoal(url: URL) {
        toast.show(message: "Understanding browser task…", isError: false, autoDismiss: false)
        transcriptionTask = Task {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                guard let serviceToken = tokenState.token, !serviceToken.isEmpty else {
                    throw BackendError.missingServiceToken
                }
                let goal = try await backend.transcribeAudio(at: url, serviceToken: serviceToken)
                guard !Task.isCancelled else { return }
                guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    toast.show(message: "No browser task detected.", isError: false)
                    return
                }
                onGoal?(goal)
            } catch {
                guard !Task.isCancelled else { return }
                if case BackendError.missingServiceToken = error {
                    openSettings?()
                }
                toast.show(message: error.localizedDescription, isError: true)
            }
        }
    }
}
