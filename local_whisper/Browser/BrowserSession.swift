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

    private let toast: ToastPresenter
    private let sidecar: BrowserSidecar
    private let logger = Logger(subsystem: "brauliopf.local-whisper", category: "browser")

    init(toast: ToastPresenter, sidecar: BrowserSidecar) {
        self.toast = toast
        self.sidecar = sidecar
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
        logger.info("browser step=command_received status=accepted")
        do {
            try sidecar.start()
            try sidecar.startBrowser()
            toast.show(message: "Browser ready.", isError: false)
        } catch {
            state = .stopped
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
        logger.info("browser step=stop status=ok")
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
