import Foundation

@MainActor
@Observable
final class VoiceTranscription {
    var openSettings: (() -> Void)?
    var setEscapeEnabled: ((Bool) -> Void)?

    private let backend: any BackendClienting
    private let keychain: any Keychaining
    private let toast: ToastPresenter
    private let recorder = AudioRecorder()
    private var transcribeTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private(set) var isRecording = false
    private(set) var isComputerUseRecording = false
    private var isTranscribing = false
    private var isStartingRecording = false
    private var computerUseResult: ((Result<String, Error>) -> Void)?

    private static let minimumRecordingDuration: TimeInterval = 0.5

    init(
        backend: any BackendClienting,
        keychain: any Keychaining,
        toast: ToastPresenter
    ) {
        self.backend = backend
        self.keychain = keychain
        self.toast = toast
    }

    func cancelInFlightWork() {
        transcribeTask?.cancel()
        isTranscribing = false
        computerUseResult = nil
        isComputerUseRecording = false
    }

    func toggle() {
        if isRecording {
            finishAndTranscribe()
            return
        }
        if isTranscribing || isStartingRecording { return }
        startRecording()
    }

    func toggleForComputerUse(onResult: @escaping (Result<String, Error>) -> Void) {
        if !isRecording {
            computerUseResult = onResult
            isComputerUseRecording = true
        }
        toggle()
    }

    func cancelRecording(showToast: Bool = true) {
        guard isRecording else { return }
        isRecording = false
        setEscapeEnabled?(false)
        maxDurationTask?.cancel()
        maxDurationTask = nil
        recorder.cancel()
        computerUseResult = nil
        isComputerUseRecording = false
        if showToast {
            toast.show(message: "Recording cancelled", isError: false)
        }
    }

    private func startRecording() {
        guard keychain.hasServiceToken else {
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
                message: isComputerUseRecording ? "Recording… press ⌃⌥A to stop" : "Recording… press ⌃⌥W to stop",
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
                    let text = try await backend.transcribeAudio(
                        at: url,
                        serviceToken: serviceToken
                    )
                    guard !Task.isCancelled else { return }
                    guard !text.isEmpty else {
                        if let computerUseResult {
                            self.computerUseResult = nil
                            self.isComputerUseRecording = false
                            computerUseResult(.success(""))
                        } else {
                            toast.show(message: "No speech detected.", isError: false)
                        }
                        return
                    }
                    if let computerUseResult {
                        self.computerUseResult = nil
                        self.isComputerUseRecording = false
                        computerUseResult(.success(text))
                    } else {
                        Clipboard.copy(text)
                        toast.show(message: "Copied to clipboard", isError: false)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    if let computerUseResult {
                        self.computerUseResult = nil
                        self.isComputerUseRecording = false
                        computerUseResult(.failure(error))
                    } else {
                        toast.show(message: error.localizedDescription, isError: true)
                    }
                    throw error
                }
            }
        }
    }

}
