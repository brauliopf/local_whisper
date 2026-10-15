import Foundation
import OSLog

@MainActor
@Observable
final class BrowserSession {
    enum State: Equatable {
        case idle
        case launching
        case running
        case pausedForUser
        case pausedForConfirmation
        case blocked
        case stopped
    }

    private(set) var state: State = .idle
    private(set) var snapshot: BrowserPageSnapshot?
    var onPlan: ((String, BackendBrowserPlanResponse) -> Void)?
    var onReadyForGoal: (() -> Void)?

    private let toast: ToastPresenter
    private let sidecar: BrowserSidecar
    private let backend: any BackendClienting
    private let tokenState: ServiceTokenState
    private let logger = Logger(subsystem: "brauliopf.local-whisper", category: "browser")
    private var planningSessionID: String?
    private var planningTask: Task<Void, Never>?
    private var captureGoalWhenReady = false

    private static let policyVersion = "browser-navigation-v1"
    private static let capabilityPolicy: [String: Any] = [
        "version": policyVersion,
        "allowed_actions": ["navigate", "click", "select", "type_non_sensitive", "scroll"],
        "single_tab": true,
    ]

    init(
        toast: ToastPresenter,
        sidecar: BrowserSidecar,
        backend: any BackendClienting,
        tokenState: ServiceTokenState
    ) {
        self.toast = toast
        self.sidecar = sidecar
        self.backend = backend
        self.tokenState = tokenState
        sidecar.onResponse = { [weak self] response in
            self?.handle(response)
        }
        sidecar.onExit = { [weak self] status in
            guard let self else { return }
            if self.state != .idle && self.state != .stopped {
                self.state = .stopped
                self.toast.show(message: "The browser helper stopped unexpectedly.", isError: true)
            }
            self.logger.info("browser sidecar exited status=\(status)")
        }
    }

    var isActive: Bool {
        switch state {
        case .idle, .stopped:
            return false
        case .launching, .running, .pausedForUser, .pausedForConfirmation, .blocked:
            return true
        }
    }

    func browseWeb() {
        guard !isActive else {
            toast.show(message: "A browser task is already running.", isError: false)
            return
        }

        state = .launching
        planningSessionID = UUID().uuidString
        captureGoalWhenReady = true
        logger.info("browser step=command_received status=accepted")
        do {
            try sidecar.start()
            try sidecar.startBrowser()
            toast.show(message: "Browser ready.", isError: false)
        } catch {
            state = .stopped
            captureGoalWhenReady = false
            toast.show(message: error.localizedDescription, isError: true)
            logger.error("browser step=launch status=failed category=helper_unavailable")
        }
    }

    func pause() {
        guard state == .running else { return }
        do {
            try sidecar.pause()
            state = .pausedForUser
            logger.info("browser step=pause status=ok")
        } catch {
            showFailure(error)
        }
    }

    func resume() {
        guard state == .pausedForUser else { return }
        do {
            try sidecar.resume()
            state = .running
            logger.info("browser step=resume status=ok")
        } catch {
            showFailure(error)
        }
    }

    func stop() {
        guard isActive else { return }
        sidecar.stop()
        state = .stopped
        snapshot = nil
        planningTask?.cancel()
        planningTask = nil
        planningSessionID = nil
        captureGoalWhenReady = false
        logger.info("browser step=stop status=ok")
    }

    func requestPlan(for goal: String) {
        guard state == .running, let snapshot, let sessionID = planningSessionID else {
            toast.show(message: "Start the browser before creating a plan.", isError: true)
            return
        }
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else {
            toast.show(message: "Tell me what you want the browser to do.", isError: true)
            return
        }
        guard let serviceToken = tokenState.token, !serviceToken.isEmpty else {
            toast.show(message: "Add the backend service token in Settings.", isError: true)
            return
        }
        planningTask?.cancel()

        do {
            let encoder = JSONEncoder()
            let pageState = try encoder.encode(snapshot)
            let capabilityPolicy = try JSONSerialization.data(withJSONObject: Self.capabilityPolicy)
            toast.show(message: "Creating browser plan…", isError: false, autoDismiss: false)
            logger.info("browser step=plan_request status=sent")
            planningTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let response = try await backend.requestBrowserPlan(
                        goal: trimmedGoal,
                        pageStateJSON: pageState,
                        capabilityPolicyJSON: capabilityPolicy,
                        policyVersion: Self.policyVersion,
                        sessionID: sessionID,
                        serviceToken: serviceToken
                    )
                    guard response.policyVersion == Self.policyVersion,
                          response.stateHash == snapshot.stateHash,
                          !response.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !response.planID.isEmpty,
                          response.safetyReview == "approved",
                          let expiresAt = ISO8601DateFormatter().date(from: response.expiresAt),
                          expiresAt > Date() else {
                        throw BackendError.invalidResponse
                    }
                    guard self.state == .running,
                          self.planningSessionID == sessionID,
                          self.snapshot?.stateHash == response.stateHash else {
                        throw BackendError.invalidResponse
                    }
                    logger.info("browser step=plan_response status=received request_id=\(response.requestID, privacy: .public)")
                    onPlan?(trimmedGoal, response)
                    do {
                        try writePlanFile(goal: trimmedGoal, response: response)
                    } catch {
                        logger.error("browser step=plan_file status=failed category=storage_error")
                    }
                    try sidecar.execute(code: response.code, stateHash: response.stateHash, policyVersion: response.policyVersion, expiresAt: response.expiresAt)
                    toast.show(message: "Executing browser plan…", isError: false, autoDismiss: false)
                } catch is CancellationError {
                    return
                } catch {
                    logger.error("browser step=plan_request status=failed category=backend_error")
                    toast.show(message: error.localizedDescription, isError: true)
                }
            }
        } catch {
            toast.show(message: "Couldn't prepare the browser snapshot.", isError: true)
        }
    }

    private func writePlanFile(goal: String, response: BackendBrowserPlanResponse) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".runs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let filename = "\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")).md"
        let contents = """
        # Browser plan

        - Goal: \(goal)
        - Plan ID: \(response.planID)
        - Policy version: \(response.policyVersion)
        - State hash: \(response.stateHash)
        - Expires at: \(response.expiresAt)

        ## Generated Playwright code

        ```javascript
        \(response.code)
        ```
        """
        try contents.write(to: directory.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }

    func requestSnapshot() {
        guard state == .running else { return }
        do {
            try sidecar.snapshot()
            logger.info("browser step=snapshot_request status=sent")
        } catch {
            showFailure(error)
        }
    }

    private func handle(_ response: BrowserSidecarResponse) {
        guard response.ok else {
            state = .blocked
            let message = response.error ?? "The browser helper rejected the request."
            toast.show(message: message, isError: true)
            logger.error("browser step=sidecar_response status=failed category=\(response.status.rawValue, privacy: .public)")
            return
        }

        switch response.status {
        case .idle:
            state = .idle
        case .running:
            state = .running
            if captureGoalWhenReady {
                captureGoalWhenReady = false
                onReadyForGoal?()
            }
        case .paused:
            state = .pausedForUser
        case .stopped:
            state = .stopped
        }
        snapshot = response.snapshot ?? snapshot
        logger.info("browser step=sidecar_response status=ok state=\(response.status.rawValue, privacy: .public)")
    }

    private func showFailure(_ error: Error) {
        toast.show(message: error.localizedDescription, isError: true)
        logger.error("browser step=operation status=failed category=sidecar_error")
    }
}
