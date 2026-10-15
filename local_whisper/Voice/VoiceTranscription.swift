import Foundation

@MainActor
@Observable
final class VoiceTranscription {
    var openSettings: (() -> Void)?
    var setEscapeEnabled: ((Bool) -> Void)?

    private let backend: any BackendClienting
    private let keychain: any Keychaining
    private let toast: ToastPresenter
    private let capture: VoiceCapture
    private var transcribeTask: Task<Void, Never>?
    private var isTranscribing = false

    init(
        backend: any BackendClienting,
        keychain: any Keychaining,
        toast: ToastPresenter
    ) {
        self.backend = backend
        self.keychain = keychain
        self.toast = toast
        self.capture = VoiceCapture(toast: toast)
        capture.onRecordingStateChanged = { [weak self] recording in
            self?.setEscapeEnabled?(recording)
        }
        capture.onRecordingFinished = { [weak self] url in
            self?.transcribe(url: url)
        }
    }

    func cancelInFlightWork() {
        transcribeTask?.cancel()
        transcribeTask = nil
        isTranscribing = false
    }

    func toggle() {
        guard !isTranscribing else { return }
        guard keychain.hasServiceToken else {
            openSettings?()
            return
        }
        capture.toggle(prompt: "Recording… press ⌃⌥W to stop")
    }

    func cancelRecording(showToast: Bool = true) {
        capture.cancel(showToast: showToast)
    }

    private func transcribe(url: URL) {
        isTranscribing = true
        toast.show(message: "Making magic…", isError: false, autoDismiss: false)
        transcribeTask = Task {
            defer {
                isTranscribing = false
                try? FileManager.default.removeItem(at: url)
            }
            await Telemetry.instrument(operation: "audio_transcription", trigger: "hotkey") {
                do {
                    guard let serviceToken = keychain.loadServiceToken(), !serviceToken.isEmpty else {
                        throw BackendError.missingServiceToken
                    }
                    let text = try await backend.transcribeAudio(at: url, serviceToken: serviceToken)
                    guard !Task.isCancelled else { return }
                    guard !text.isEmpty else {
                        toast.show(message: "No speech detected.", isError: false)
                        return
                    }
                    Clipboard.copy(text)
                    toast.show(message: "Copied to clipboard", isError: false)
                } catch {
                    guard !Task.isCancelled else { return }
                    toast.show(message: error.localizedDescription, isError: true)
                    throw error
                }
            }
        }
    }
}
