import Foundation

struct BrowserPageSnapshot: Codable, Sendable {
    let url: String
    let title: String
}

enum BrowserSidecarStatus: String, Codable, Sendable {
    case idle
    case running
    case paused
    case stopped
}

struct BrowserSidecarResponse: Codable, Sendable {
    let id: String
    let ok: Bool
    let status: BrowserSidecarStatus
    let snapshot: BrowserPageSnapshot?
    let error: String?
}

enum BrowserSidecarError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "The browser helper is not installed."
        case .launchFailed(let message):
            return "The browser helper could not start: \(message)"
        case .unavailable:
            return "The browser helper is unavailable."
        }
    }
}

@MainActor
final class BrowserSidecar {
    var onResponse: ((BrowserSidecarResponse) -> Void)?
    var onExit: ((Int32) -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var outputBuffer = Data()
    private var isStarted = false

    func start() throws {
        guard !isStarted else { return }
        guard let executable = Self.executableURL() else {
            throw BrowserSidecarError.executableNotFound
        }

        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.receive(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.isStarted = false
                self?.onExit?(process.terminationStatus)
            }
        }

        do {
            try process.run()
            isStarted = true
        } catch {
            throw BrowserSidecarError.launchFailed(error.localizedDescription)
        }
    }

    func startBrowser() throws {
        try send(type: "start")
    }

    func snapshot() throws {
        try send(type: "snapshot")
    }

    func pause() throws {
        try send(type: "pause")
    }

    func resume() throws {
        try send(type: "resume")
    }

    func stop() {
        if isStarted {
            try? send(type: "stop")
        }
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        isStarted = false
    }

    private func send(type: String) throws {
        guard isStarted else { throw BrowserSidecarError.unavailable }
        let command: [String: String] = ["id": UUID().uuidString, "type": type]
        let data = try JSONSerialization.data(withJSONObject: command)
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))
    }

    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard let response = try? JSONDecoder().decode(BrowserSidecarResponse.self, from: line) else {
                continue
            }
            onResponse?(response)
        }
    }

    private static func executableURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["BROWSER_SIDECAR_PATH"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.url(forResource: "browser-sidecar", withExtension: nil)
    }
}
