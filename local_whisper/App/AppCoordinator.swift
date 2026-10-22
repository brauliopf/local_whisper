import Foundation

@MainActor
@Observable
final class AppCoordinator {
    var openSettings: (() -> Void)? {
        didSet {
            encouragement.openSettings = openSettings
            voice.openSettings = openSettings
            browserVoiceGoal.openSettings = openSettings
            screenshot.openSettings = openSettings
        }
    }

    var openPlanPreview: (() -> Void)?
    private(set) var planPreview: (goal: String, code: String)?

    private let toast = ToastPresenter()
    private let hotkeys = Hotkeys()
    let tokenState: ServiceTokenState
    private let encouragement: Encouragement
    private let voice: VoiceTranscription
    private let browserVoiceGoal: BrowserVoiceGoal
    private let screenshot: ScreenshotOCR
    let countdown: Countdown
    let browser: BrowserSession
    let grocery: GroceryTaskCoordinator
    private var didFinishLaunching = false

    convenience init() {
        self.init(
            backend: BackendClient(),
            keychain: KeychainStore()
        )
    }

    init(
        backend: any BackendClienting,
        keychain: any Keychaining
    ) {
        self.tokenState = ServiceTokenState(keychain: keychain)
        self.encouragement = Encouragement(backend: backend, tokenState: tokenState, toast: toast)
        self.voice = VoiceTranscription(backend: backend, tokenState: tokenState, toast: toast)
        self.browserVoiceGoal = BrowserVoiceGoal(backend: backend, tokenState: tokenState, toast: toast)
        self.screenshot = ScreenshotOCR(backend: backend, tokenState: tokenState, toast: toast)
        self.countdown = Countdown(toast: toast)
        self.browser = BrowserSession(toast: toast, sidecar: BrowserSidecar(), backend: backend, tokenState: tokenState)
        self.grocery = GroceryTaskCoordinator()

        browser.onReadyForGoal = { [weak self] in
            self?.browserVoiceGoal.toggle()
        }
        browserVoiceGoal.onGoal = { [weak self] goal in
            self?.browser.requestPlan(for: goal)
        }

        voice.setEscapeEnabled = { [weak self] enabled in
            self?.hotkeys.setEscapeEnabled(enabled)
        }
        browserVoiceGoal.setEscapeEnabled = { [weak self] enabled in
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
        hotkeys.onBrowseWeb = { [weak self] in
            self?.browseWeb()
        }
        hotkeys.onCountdown = { [weak self] in
            self?.countdown.startOrExtend()
        }
        hotkeys.onSettings = { [weak self] in
            self?.openSettings?()
        }
        hotkeys.onEscape = { [weak self] in
            self?.voice.cancelRecording()
            self?.browserVoiceGoal.cancel()
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
        if !registration.browseWeb {
            toast.show(
                message: "Couldn't register ⌃⌥A — another app may already use that shortcut.",
                isError: true
            )
        }
        if !registration.countdown {
            toast.show(
                message: "Couldn't register ⌃⌥T — another app may already use that shortcut.",
                isError: true
            )
        }
        if !registration.settings {
            toast.show(
                message: "Couldn't register ⌃⌥S — another app may already use that shortcut.",
                isError: true
            )
        }
    }

    func startGrocery(request: String) {
        voice.cancelRecording(showToast: false)
        voice.cancelInFlightWork()
        browserVoiceGoal.cancel(showToast: false)
        browserVoiceGoal.cancelInFlightWork()
        screenshot.cancel()
        encouragement.cancel()
        grocery.start(request: request, signedIn: false)
        browser.browseWeb()
    }

    func browseWeb() {
        if browserVoiceGoal.isRecording {
            browserVoiceGoal.toggle()
            return
        }

        voice.cancelRecording(showToast: false)
        voice.cancelInFlightWork()
        browserVoiceGoal.cancelInFlightWork()
        screenshot.cancel()
        encouragement.cancel()

        browser.browseWeb()
    }

    func showBrowserPlan(goal: String, response: BackendBrowserPlanResponse) {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        planPreview = (goal, response.code)
        openPlanPreview?()
    }

    func showEncouragement() {
        voice.cancelRecording(showToast: false)
        voice.cancelInFlightWork()
        screenshot.cancel()
        encouragement.show()
    }

    func toggleTranscription() {
        browserVoiceGoal.cancel(showToast: false)
        browserVoiceGoal.cancelInFlightWork()
        screenshot.cancel()
        encouragement.cancel()
        voice.toggle()
    }

    func readScreenshot() {
        voice.cancelRecording(showToast: false)
        voice.cancelInFlightWork()
        browserVoiceGoal.cancel(showToast: false)
        browserVoiceGoal.cancelInFlightWork()
        encouragement.cancel()
        screenshot.captureAndRead()
    }
}
