import Foundation

@MainActor
@Observable
final class VoiceTranscription {
    var openSettings: (() -> Void)?
    var setEscapeEnabled: ((Bool) -> Void)?

    private let openAI: any OpenAIClienting
    private let keychain: any Keychaining
    private let toast: ToastPresenter
    private let recorder = AudioRecorder()
    private var transcribeTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var isRecording = false
    private var isTranscribing = false
    private var isStartingRecording = false

    private static let minimumRecordingDuration: TimeInterval = 0.5

    init(
        openAI: any OpenAIClienting,
        keychain: any Keychaining,
        toast: ToastPresenter
    ) {
        self.openAI = openAI
        self.keychain = keychain
        self.toast = toast
    }

    func cancelInFlightWork() {
        transcribeTask?.cancel()
        isTranscribing = false
    }

    func toggle() {
        if isRecording {
            finishAndTranscribe()
            return
        }
        if isTranscribing || isStartingRecording { return }
        startRecording()
    }

    func cancelRecording(showToast: Bool = true) {
        guard isRecording else { return }
        isRecording = false
        setEscapeEnabled?(false)
        maxDurationTask?.cancel()
        maxDurationTask = nil
        recorder.cancel()
        if showToast {
            toast.show(message: "Recording cancelled", isError: false)
        }
    }

    private func startRecording() {
        guard keychain.hasAPIKey else {
            openSettings?()
            return
        }

        isStartingRecording = true

        Task {
            defer { isStartingRecording = false }

            let allowed = await recorder.hasMicrophoneAccess()
            guard allowed else {
                toast.show(message: "Microphone access is required.", isError: true)
                return
            }

            do {
                try recorder.start()
            } catch {
                toast.show(message: error.localizedDescription, isError: true)
                return
            }

            isRecording = true
            setEscapeEnabled?(true)
            toast.show(
                message: "Recording… press ⌃⌥W to stop",
                isError: false,
                autoDismiss: false
            )

            maxDurationTask?.cancel()
            maxDurationTask = Task {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                finishAndTranscribe()
            }
        }
    }

    private func finishAndTranscribe() {
        guard isRecording else { return }
        isRecording = false
        setEscapeEnabled?(false)
        maxDurationTask?.cancel()
        maxDurationTask = nil

        let url = recorder.stop()
        let duration = recorder.duration

        guard let url else {
            toast.show(message: "Couldn't start recording.", isError: true)
            return
        }

        guard duration >= Self.minimumRecordingDuration else {
            try? FileManager.default.removeItem(at: url)
            toast.show(message: "Nothing to transcribe", isError: false)
            return
        }

        isTranscribing = true
        toast.show(message: "Transcribing…", isError: false, autoDismiss: false)

        transcribeTask = Task {
            defer {
                isTranscribing = false
                try? FileManager.default.removeItem(at: url)
            }
            do {
                guard let apiKey = keychain.loadAPIKey(), !apiKey.isEmpty else {
                    throw OpenAIError.missingAPIKey
                }
                let text = try await openAI.transcribeAudio(at: url, apiKey: apiKey, model: ModelSettings.transcribe)
                guard !Task.isCancelled else { return }
                Clipboard.copy(text)
                toast.show(message: "Copied to clipboard", isError: false)
            } catch {
                guard !Task.isCancelled else { return }
                toast.show(message: error.localizedDescription, isError: true)
            }
        }
    }
}
