import Foundation

@MainActor
final class VoiceCapture {
    var onRecordingFinished: ((URL) -> Void)?
    var onRecordingCancelled: (() -> Void)?
    var onRecordingStateChanged: ((Bool) -> Void)?

    private let recorder: AudioRecorder
    private let toast: ToastPresenter
    private var maxDurationTask: Task<Void, Never>?
    private(set) var isRecording = false
    private var isStarting = false

    private static let minimumDuration: TimeInterval = 0.5
    private static let maximumDuration: Duration = .seconds(120)

    init(recorder: AudioRecorder = AudioRecorder(), toast: ToastPresenter) {
        self.recorder = recorder
        self.toast = toast
    }

    func toggle(prompt: String) {
        if isRecording {
            finish()
        } else if !isStarting {
            start(prompt: prompt)
        }
    }

    func cancel(showToast: Bool = true) {
        guard isRecording else { return }
        isRecording = false
        isStarting = false
        maxDurationTask?.cancel()
        maxDurationTask = nil
        recorder.cancel()
        onRecordingStateChanged?(false)
        if showToast {
            toast.show(message: "Recording cancelled", isError: false)
        }
        onRecordingCancelled?()
    }

    private func start(prompt: String) {
        isStarting = true
        Task {
            defer { isStarting = false }

            guard await recorder.hasMicrophoneAccess() else {
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
            onRecordingStateChanged?(true)
            toast.show(message: prompt, isError: false, autoDismiss: false)

            maxDurationTask?.cancel()
            maxDurationTask = Task { [weak self] in
                try? await Task.sleep(for: Self.maximumDuration)
                guard !Task.isCancelled else { return }
                self?.finish()
            }
        }
    }

    private func finish() {
        guard isRecording else { return }
        isRecording = false
        maxDurationTask?.cancel()
        maxDurationTask = nil
        onRecordingStateChanged?(false)

        let url = recorder.stop()
        let duration = recorder.duration
        guard let url else {
            toast.show(message: "Couldn't start recording.", isError: true)
            return
        }
        guard duration >= Self.minimumDuration else {
            try? FileManager.default.removeItem(at: url)
            toast.show(message: "Nothing to transcribe", isError: false)
            return
        }
        onRecordingFinished?(url)
    }
}
