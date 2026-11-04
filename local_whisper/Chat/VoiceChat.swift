import Foundation
import Observation
import SwiftUI

@MainActor
enum VoiceChatPhase: Equatable {
    case idle
    case recording
    case transcribing
    case completing
    case response
    case failed
}

@MainActor
@Observable
final class VoiceChat {
    var phase: VoiceChatPhase = .idle
    var response = ""
    var errorMessage = ""
    var openWindow: (() -> Void)?
    var openSettings: (() -> Void)?
    var setEscapeEnabled: ((Bool) -> Void)?

    private let backend: any BackendClienting
    private let tokenState: ServiceTokenState
    private let toast: ToastPresenter
    private let capture: any VoiceCapturing
    private var chatTask: Task<Void, Never>?

    init(
        backend: any BackendClienting,
        tokenState: ServiceTokenState,
        toast: ToastPresenter,
        capture: (any VoiceCapturing)? = nil
    ) {
        self.backend = backend
        self.tokenState = tokenState
        self.toast = toast
        self.capture = capture ?? VoiceCapture(toast: toast)

        self.capture.onRecordingStateChanged = { [weak self] recording in
            self?.setEscapeEnabled?(recording)
            if recording {
                self?.phase = .recording
            } else if self?.phase == .recording {
                self?.phase = .transcribing
                self?.toast.show(message: "Transcribing…", isError: false, autoDismiss: false)
            }
        }
        self.capture.onRecordingFinished = { [weak self] url in
            self?.complete(url: url)
        }
    }

    func toggle() {
        guard chatTask == nil else { return }
        guard tokenState.token?.isEmpty == false else {
            openSettings?()
            return
        }

        if phase == .idle {
            response = ""
            errorMessage = ""
            openWindow?()
        }
        capture.toggle(prompt: "Recording… press ⌃⌥C to stop")
    }

    func cancelRecording(showToast: Bool = true) {
        capture.cancel(showToast: showToast)
        if phase == .transcribing {
            phase = .idle
        }
    }

    func cancelInFlightWork() {
        capture.cancel(showToast: false)
        chatTask?.cancel()
        chatTask = nil
        if phase != .response {
            phase = .idle
        }
    }

    private func complete(url: URL) {
        phase = .transcribing
        chatTask = Task { [weak self] in
            defer {
                try? FileManager.default.removeItem(at: url)
                self?.chatTask = nil
            }

            do {
                guard let self else { return }
                guard let serviceToken = tokenState.token, !serviceToken.isEmpty else {
                    throw BackendError.missingServiceToken
                }

                let transcript = try await backend.transcribeSourceAudio(
                    at: url,
                    serviceToken: serviceToken
                )
                guard !Task.isCancelled else { return }
                let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedTranscript.isEmpty else {
                    phase = .failed
                    errorMessage = "No speech detected."
                    toast.show(message: errorMessage, isError: false)
                    return
                }

                phase = .completing
                toast.show(message: "Thinking…", isError: false, autoDismiss: false)
                let text = try await backend.complete(text: trimmedTranscript, serviceToken: serviceToken)
                guard !Task.isCancelled else { return }
                response = text
                phase = .response
                toast.show(message: "Response ready", isError: false)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.phase = .failed
                self.errorMessage = error.localizedDescription
                self.toast.show(message: self.errorMessage, isError: true)
            }
        }
    }
}

struct VoiceChatView: View {
    let chat: VoiceChat

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Voice Chat")
                .font(.title2.weight(.semibold))

            switch chat.phase {
            case .idle:
                Text("Press ⌃⌥C to ask a question.")
                    .foregroundStyle(.secondary)
            case .recording:
                Label("Recording… press ⌃⌥C to stop", systemImage: "waveform")
            case .transcribing:
                ProgressView("Transcribing…")
            case .completing:
                ProgressView("Thinking…")
            case .response:
                ScrollView {
                    Text(chat.response)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            case .failed:
                Label(chat.errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 260)
    }
}
