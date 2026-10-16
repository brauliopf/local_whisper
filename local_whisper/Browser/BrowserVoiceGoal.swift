import Foundation

@MainActor
final class BrowserVoiceGoal {
    var setEscapeEnabled: ((Bool) -> Void)?
    var onAudioReady: ((URL) -> Void)?

    private let capture: VoiceCapture

    init(toast: ToastPresenter) {
        self.capture = VoiceCapture(toast: toast)
        capture.onRecordingStateChanged = { [weak self] recording in
            self?.setEscapeEnabled?(recording)
        }
        capture.onRecordingFinished = { [weak self] url in
            self?.onAudioReady?(url)
        }
    }

    var isRecording: Bool { capture.isRecording }

    func toggle() {
        capture.toggle(prompt: "Describe the browser task… press ⌃⌥A to stop")
    }

    func cancel(showToast: Bool = true) {
        capture.cancel(showToast: showToast)
    }
}
