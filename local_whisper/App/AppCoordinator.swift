import Foundation

@MainActor
@Observable
final class AppCoordinator {
    var openSettings: (() -> Void)? {
        didSet {
            encouragement.openSettings = openSettings
            voice.openSettings = openSettings
            screenshot.openSettings = openSettings
        }
    }

    private let toast = ToastPresenter()
    private let hotkeys = Hotkeys()
    private let encouragement: Encouragement
    private let voice: VoiceTranscription
    private let screenshot: ScreenshotOCR
    let countdown: Countdown
    private var didFinishLaunching = false

    convenience init() {
        self.init(openAI: OpenAIClient(), keychain: KeychainStore())
    }

    init(
        openAI: any OpenAIClienting,
        keychain: any Keychaining
    ) {
        self.encouragement = Encouragement(openAI: openAI, keychain: keychain, toast: toast)
        self.voice = VoiceTranscription(openAI: openAI, keychain: keychain, toast: toast)
        self.screenshot = ScreenshotOCR(openAI: openAI, keychain: keychain, toast: toast)
        self.countdown = Countdown(toast: toast)

        voice.setEscapeEnabled = { [weak self] enabled in
            self?.hotkeys.setEscapeEnabled(enabled)
        }
        hotkeys.onEncouragement = { [weak self] in
            self?.showEncouragement()
        }
        hotkeys.onTranscribe = { [weak self] in
            self?.toggleTranscription()
        }
        hotkeys.onScreenshot = { [weak self] in
            self?.readScreenshot()
        }
        hotkeys.onCountdown = { [weak self] in
            self?.countdown.handleHotkey()
        }
        hotkeys.onEscape = { [weak self] in
            self?.voice.cancelRecording()
        }
    }

    func finishLaunching() {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true

        let registration = hotkeys.start()
        if !registration.encouragement {
            toast.show(
                message: "Couldn't register ⌃⌥E — another app may already use that shortcut.",
                isError: true
            )
        }
        if !registration.transcribe {
            toast.show(
                message: "Couldn't register ⌃⌥W — another app may already use that shortcut.",
                isError: true
            )
        }
        if !registration.screenshot {
            toast.show(
                message: "Couldn't register ⌃⌥R — another app may already use that shortcut.",
                isError: true
            )
        }
        if !registration.countdown {
            toast.show(
                message: "Couldn't register ⌃⌥T — another app may already use that shortcut.",
                isError: true
            )
        }
    }

    func showEncouragement() {
        voice.cancelRecording(showToast: false)
        voice.cancelInFlightWork()
        screenshot.cancel()
        encouragement.show()
    }

    func toggleTranscription() {
        screenshot.cancel()
        encouragement.cancel()
        voice.toggle()
    }

    func readScreenshot() {
        voice.cancelRecording(showToast: false)
        voice.cancelInFlightWork()
        encouragement.cancel()
        screenshot.captureAndRead()
    }
}
