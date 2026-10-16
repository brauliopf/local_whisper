import Foundation

@MainActor
@Observable
final class BrowserCommandCoordinator {
    enum State: Equatable {
        case idle
        case launching
        case ready
        case recording
        case snapshotting
        case transcribing
        case planning
        case executing
        case paused
        case stopped
    }

    private(set) var state: State = .idle
    var openSettings: (() -> Void)?
    var setEscapeEnabled: ((Bool) -> Void)?

    private let browser: BrowserSession
    private let backend: any BackendClienting
    private let tokenState: ServiceTokenState
    private let toast: ToastPresenter
    private let voiceGoal: BrowserVoiceGoal
    private var transcriptionTask: Task<Void, Never>?

    init(
        browser: BrowserSession,
        backend: any BackendClienting,
        tokenState: ServiceTokenState,
        toast: ToastPresenter
    ) {
        self.browser = browser
        self.backend = backend
        self.tokenState = tokenState
        self.toast = toast
        self.voiceGoal = BrowserVoiceGoal(toast: toast)

        voiceGoal.setEscapeEnabled = { [weak self] enabled in
            self?.setEscapeEnabled?(enabled)
        }
        voiceGoal.onAudioReady = { [weak self] url in
            self?.audioReady(url)
        }
        browser.onPlan = { [weak self] _, _ in
            self?.state = .executing
        }
        browser.onCommandFinished = { [weak self] success in
            self?.commandFinished(success: success)
        }
    }

    var isRecording: Bool { voiceGoal.isRecording }

    func toggle() {
        switch browser.state {
        case .idle, .stopped:
            guard !voiceGoal.isRecording else {
                showBusyMessage()
                return
            }
            state = .launching
            browser.browseWeb()
            toast.show(message: "Browser launching…", isError: false)
        case .launching:
            toast.show(message: "Browser is still launching.", isError: false)
        case .pausedForUser, .pausedForConfirmation:
            state = .paused
            toast.show(message: "Resume the browser before recording a command.", isError: true)
        case .blocked:
            toast.show(message: "The browser is unavailable. Stop it and try again.", isError: true)
        case .running:
            guard Self.canStartRecording(
                browserState: browser.state,
                commandState: state,
                browserIsBusy: browser.isCommandBusy
            ) else {
                showBusyMessage()
                return
            }
            state = .recording
            voiceGoal.toggle()
        }
    }

    func cancel() {
        voiceGoal.cancel()
        if state == .recording {
            state = .ready
        }
    }

    private func audioReady(_ url: URL) {
        guard state == .recording, browser.state == .running else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        state = .snapshotting
        toast.show(message: "Refreshing browser state…", isError: false, autoDismiss: false)
        browser.requestSnapshot { [weak self] result in
            guard let self else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            switch result {
            case .success:
                self.transcribe(url: url)
            case .failure(let error):
                try? FileManager.default.removeItem(at: url)
                self.commandFailed(error)
            }
        }
    }

    private func transcribe(url: URL) {
        state = .transcribing
        toast.show(message: "Understanding browser task…", isError: false, autoDismiss: false)
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: url)
                transcriptionTask = nil
            }
            do {
                guard let serviceToken = tokenState.token, !serviceToken.isEmpty else {
                    throw BackendError.missingServiceToken
                }
                let goal = try await backend.transcribeAudio(at: url, serviceToken: serviceToken)
                guard !Task.isCancelled else { return }
                let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedGoal.isEmpty else {
                    throw BackendError.invalidResponse
                }
                state = .planning
                browser.requestPlan(for: trimmedGoal)
                if !browser.isCommandBusy {
                    commandFailed(BackendError.invalidResponse)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if case BackendError.missingServiceToken = error {
                    openSettings?()
                }
                commandFailed(error)
            }
        }
    }

    private func commandFinished(success: Bool) {
        guard state != .stopped else { return }
        state = browser.state == .pausedForUser ? .paused : .ready
        if success {
            toast.show(message: "Ready for the next browser command.", isError: false)
        }
    }

    private func commandFailed(_ error: Error) {
        guard state != .stopped else { return }
        state = browser.state == .pausedForUser ? .paused : .ready
        toast.show(message: error.localizedDescription, isError: true)
    }

    static func canStartRecording(
        browserState: BrowserSession.State,
        commandState: State,
        browserIsBusy: Bool
    ) -> Bool {
        browserState == .running
            && !browserIsBusy
            && [.ready, .idle, .stopped].contains(commandState)
    }

    private func showBusyMessage() {
        toast.show(message: "Browser is still working on the previous command.", isError: false)
    }
}
