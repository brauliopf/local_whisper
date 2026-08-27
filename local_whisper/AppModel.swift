import AppKit
import Foundation

@MainActor
@Observable
final class AppModel {
    var openSettings: (() -> Void)?

    private let toastController = ToastPanelController()
    private let openAIService = OpenAIService()
    private let hotkeyManager = GlobalHotkeyManager()
    private let audioRecorder = AudioRecorder()
    private var fetchTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var screenshotTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var didFinishLaunching = false
    private var isRecording = false
    private var isTranscribing = false
    private var isStartingRecording = false

    private static let minimumRecordingDuration: TimeInterval = 0.5

    init() {
        hotkeyManager.onEncouragement = { [weak self] in
            self?.showEncouragement()
        }
        hotkeyManager.onTranscribe = { [weak self] in
            self?.toggleTranscription()
        }
        hotkeyManager.onScreenshot = { [weak self] in
            self?.readScreenshot()
        }
        hotkeyManager.onEscape = { [weak self] in
            self?.cancelRecording()
        }
    }

    func finishLaunching() {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true

        let registration = hotkeyManager.start()
        if !registration.encouragement {
            toastController.show(
                message: "Couldn't register ⌃⌥E — another app may already use that shortcut.",
                isError: true
            )
        }
        if !registration.transcribe {
            toastController.show(
                message: "Couldn't register ⌃⌥W — another app may already use that shortcut.",
                isError: true
            )
        }
        if !registration.screenshot {
            toastController.show(
                message: "Couldn't register ⌃⌥R — another app may already use that shortcut.",
                isError: true
            )
        }
    }

    func showEncouragement() {
        if isRecording {
            cancelRecording(showToast: false)
        }
        transcribeTask?.cancel()
        isTranscribing = false
        screenshotTask?.cancel()
        ScreenshotCapture.cancel()

        guard KeychainService.hasAPIKey else {
            openSettings?()
            return
        }

        fetchTask?.cancel()
        toastController.show(message: "Thinking…", isError: false)

        fetchTask = Task {
            do {
                let message = try await openAIService.fetchEncouragement()
                guard !Task.isCancelled else { return }
                toastController.show(message: message, isError: false)
            } catch {
                guard !Task.isCancelled else { return }
                toastController.show(message: error.localizedDescription, isError: true)
            }
        }
    }

    func toggleTranscription() {
        screenshotTask?.cancel()
        ScreenshotCapture.cancel()
        if isRecording {
            finishRecordingAndTranscribe()
            return
        }
        if isTranscribing || isStartingRecording { return }
        startRecording()
    }

    private func startRecording() {
        guard KeychainService.hasAPIKey else {
            openSettings?()
            return
        }

        isStartingRecording = true
        fetchTask?.cancel()

        Task {
            defer { isStartingRecording = false }

            let allowed = await audioRecorder.hasMicrophoneAccess()
            guard allowed else {
                toastController.show(message: "Microphone access is required.", isError: true)
                return
            }

            do {
                try audioRecorder.start()
            } catch {
                toastController.show(message: error.localizedDescription, isError: true)
                return
            }

            isRecording = true
            hotkeyManager.setEscapeEnabled(true)
            toastController.show(
                message: "Recording… press ⌃⌥W to stop",
                isError: false,
                autoDismiss: false
            )

            maxDurationTask?.cancel()
            maxDurationTask = Task {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                finishRecordingAndTranscribe()
            }
        }
    }

    private func finishRecordingAndTranscribe() {
        guard isRecording else { return }
        isRecording = false
        hotkeyManager.setEscapeEnabled(false)
        maxDurationTask?.cancel()
        maxDurationTask = nil

        let url = audioRecorder.stop()
        let duration = audioRecorder.duration

        guard let url else {
            toastController.show(message: "Couldn't start recording.", isError: true)
            return
        }

        guard duration >= Self.minimumRecordingDuration else {
            try? FileManager.default.removeItem(at: url)
            toastController.show(message: "Nothing to transcribe", isError: false)
            return
        }

        isTranscribing = true
        toastController.show(message: "Transcribing…", isError: false, autoDismiss: false)

        transcribeTask = Task {
            defer {
                isTranscribing = false
                try? FileManager.default.removeItem(at: url)
            }
            do {
                let text = try await openAIService.transcribeAudio(at: url)
                guard !Task.isCancelled else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                toastController.show(message: "Copied to clipboard", isError: false)
            } catch {
                guard !Task.isCancelled else { return }
                toastController.show(message: error.localizedDescription, isError: true)
            }
        }
    }

    private func cancelRecording(showToast: Bool = true) {
        guard isRecording else { return }
        isRecording = false
        hotkeyManager.setEscapeEnabled(false)
        maxDurationTask?.cancel()
        maxDurationTask = nil
        audioRecorder.cancel()
        if showToast {
            toastController.show(message: "Recording cancelled", isError: false)
        }
    }

    func readScreenshot() {
        if isRecording {
            cancelRecording(showToast: false)
        }
        transcribeTask?.cancel()
        isTranscribing = false
        fetchTask?.cancel()
        screenshotTask?.cancel()
        ScreenshotCapture.cancel()

        guard KeychainService.hasAPIKey else {
            openSettings?()
            return
        }

        screenshotTask = Task {
            if !ScreenshotCapture.hasScreenRecordingAccess {
                let granted = ScreenshotCapture.requestScreenRecordingAccess()
                guard granted else {
                    toastController.show(message: "Screen Recording access is required.", isError: true)
                    return
                }
            }

            let url = await ScreenshotCapture.captureInteractive()
            guard !Task.isCancelled else { return }
            guard let url else { return }

            defer { try? FileManager.default.removeItem(at: url) }

            toastController.show(message: "Reading image…", isError: false, autoDismiss: false)

            do {
                let text = try await openAIService.extractText(fromImageAt: url)
                guard !Task.isCancelled else { return }
                guard let text else {
                    toastController.show(message: "No text found", isError: false)
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                toastController.show(message: "Copied to clipboard", isError: false)
            } catch {
                guard !Task.isCancelled else { return }
                toastController.show(message: error.localizedDescription, isError: true)
            }
        }
    }
}
