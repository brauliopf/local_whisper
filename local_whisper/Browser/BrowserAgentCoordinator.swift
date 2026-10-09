import Foundation

@MainActor
@Observable
final class BrowserAgentCoordinator {
    enum State: Equatable {
        case stopped
        case starting
        case idle
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting…"
            case .idle: return "Running"
            case .failed(let message): return "Failed: \(message)"
            }
        }
    }

    private let sidecar = BrowserSidecar()
    private(set) var state: State = .stopped

    init() {
        sidecar.onState = { [weak self] state, message in
            guard let self else { return }
            switch state {
            case "starting": self.state = .starting
            case "idle": self.state = .idle
            case "stopped": self.state = .stopped
            case "error": self.state = .failed(message ?? "Browser agent failed")
            default: break
            }
        }
    }

    func toggle() {
        switch state {
        case .stopped, .failed:
            start()
        case .starting, .idle:
            stop()
        }
    }

    func start() {
        guard case .stopped = state else { return }
        state = .starting
        do {
            let profile = try profileURL()
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try sidecar.start(profilePath: profile)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        sidecar.stop()
        state = .stopped
    }

    private func profileURL() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "BrowserAgent", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't find Application Support."
            ])
        }
        return support.appendingPathComponent("local-whisper/browser-profile", isDirectory: true)
    }
}
