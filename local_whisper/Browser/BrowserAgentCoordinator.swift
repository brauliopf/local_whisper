import Foundation

@MainActor
@Observable
final class BrowserAgentCoordinator {
    enum State: Equatable {
        case stopped
        case starting
        case idle
        case planning
        case awaitingConfirmation(String)
        case authenticationPaused
        case executing
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting…"
            case .idle: return "Running"
            case .planning: return "Planning…"
            case .awaitingConfirmation(let summary): return "Confirm: \(summary)"
            case .authenticationPaused: return "Authentication paused"
            case .executing: return "Executing…"
            case .failed(let message): return "Failed: \(message)"
            }
        }
    }

    private let backend: any BackendClienting
    private let keychain: any Keychaining
    private let toast: ToastPresenter
    private let sidecar = BrowserSidecar()
    private var pendingAction: BrowserPlanAction?
    private(set) var state: State = .stopped

    var isActive: Bool {
        switch state {
        case .stopped, .failed: return false
        default: return true
        }
    }

    init(
        backend: any BackendClienting,
        keychain: any Keychaining,
        toast: ToastPresenter
    ) {
        self.backend = backend
        self.keychain = keychain
        self.toast = toast
        sidecar.onState = { [weak self] state, message in
            guard let self else { return }
            switch state {
            case "starting": self.state = .starting
            case "idle": self.state = .idle
            case "stopped":
                if self.isActive { self.state = .stopped }
            case "error": self.state = .failed(message ?? "Browser agent failed")
            default: break
            }
        }
    }

    func toggle() {
        switch state {
        case .stopped, .failed:
            start()
        default:
            stop()
        }
    }

    func start() {
        guard case .stopped = state else {
            guard case .failed = state else { return }
            startProcess()
            return
        }
        startProcess()
    }

    func stop() {
        pendingAction = nil
        sidecar.stop()
        state = .stopped
    }

    func confirmPendingAction() {
        guard let pendingAction else { return }
        self.pendingAction = nil
        state = .executing
        Task { await execute(pendingAction) }
    }

    func cancelPendingAction() {
        pendingAction = nil
        state = .idle
    }

    func pauseForAuthentication() {
        guard isActive else { return }
        pendingAction = nil
        state = .authenticationPaused
    }

    func resumeAuthentication() {
        guard case .authenticationPaused = state else { return }
        state = .idle
    }

    func submitVoiceCommand(_ command: String) async {
        guard case .idle = state else { return }
        state = .planning
        do {
            if let url = Self.url(in: command) {
                _ = try await sidecar.navigate(url.absoluteString)
                state = .idle
                return
            }
            guard let token = keychain.loadServiceToken(), !token.isEmpty else {
                throw BackendError.missingServiceToken
            }
            let rawContext = try await sidecar.inspect()
            let result = rawContext["result"] as? [String: Any] ?? [:]
            let page = BrowserPageContext(
                title: result["title"] as? String ?? "",
                text: result["text"] as? String ?? ""
            )
            let plan = try await backend.planBrowser(command: command, page: page, serviceToken: token)
            if plan.action.requiresConfirmation {
                pendingAction = plan.action
                state = .awaitingConfirmation(plan.action.summary ?? "Browser action")
            } else {
                state = .executing
                await execute(plan.action)
            }
        } catch {
            state = .failed(error.localizedDescription)
            toast.show(message: error.localizedDescription, isError: true)
        }
    }

    private func startProcess() {
        state = .starting
        do {
            let profile = try profileURL()
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try sidecar.start(profilePath: profile)
        } catch {
            state = .failed(error.localizedDescription)
            toast.show(message: error.localizedDescription, isError: true)
        }
    }

    private func execute(_ action: BrowserPlanAction) async {
        do {
            var values: [String: Any] = ["type": action.type]
            if let target = action.target { values["target"] = target }
            if let direction = action.direction { values["direction"] = direction }
            if let milliseconds = action.milliseconds { values["milliseconds"] = milliseconds }
            _ = try await sidecar.execute(values)
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
            toast.show(message: error.localizedDescription, isError: true)
        }
    }

    private func profileURL() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "BrowserAgent", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't find Application Support."
            ])
        }
        return support.appendingPathComponent("local-whisper/browser-profile", isDirectory: true)
    }

    private static func url(in command: String) -> URL? {
        command.split(whereSeparator: \.isWhitespace)
            .compactMap { URL(string: String($0)) }
            .first { $0.scheme == "http" || $0.scheme == "https" }
    }
}
