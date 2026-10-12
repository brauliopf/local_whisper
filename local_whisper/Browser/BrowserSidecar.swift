import Foundation

struct BrowserControl: Codable, Sendable {
    let tag: String
    let type: String?
    let label: String?
    let name: String?
    let value: String
}

struct BrowserPageSnapshot: Codable, Sendable {
    let url: String
    let title: String
    let visibleText: String
    let controls: [BrowserControl]
    let stateHash: String
}

enum BrowserSidecarStatus: String, Codable, Sendable {
    case idle
    case running
    case paused
    case stopped
}

struct BrowserSidecarResponse: Codable, Sendable {
    let id: String
    let version: Int
    let sessionID: String
    let ok: Bool
    let status: BrowserSidecarStatus
    let snapshot: BrowserPageSnapshot?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, version, ok, status, snapshot, error
        case sessionID = "session_id"
    }
}

enum BrowserSidecarError: LocalizedError {
    case executableNotFound
    case launchFailed
    case unavailable

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "The browser helper is not installed."
        case .launchFailed:
            return "The browser helper could not start."
        case .unavailable:
            return "The browser helper is unavailable."
        }
    }
}

@MainActor
final class BrowserSidecar {
    private static let protocolVersion = 1
    private static let commandTimeout: TimeInterval = 30

    var onResponse: ((BrowserSidecarResponse) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var outputBuffer = Data()
    private var sessionID: String?

    var isStarted: Bool { process?.isRunning == true }

    func start() throws {
        guard !isStarted else { return }
        guard let executable = Self.executableURL() else {
            throw BrowserSidecarError.executableNotFound
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let sessionID = UUID().uuidString
        self.process = process
        self.input = input
        self.output = output
        self.sessionID = sessionID
        outputBuffer = Data()

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
                guard let self else { return }
                self.process = nil
                self.input = nil
                self.output = nil
                self.onExit?(process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            self.process = nil
            self.input = nil
            self.output = nil
            throw BrowserSidecarError.launchFailed
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
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        input = nil
        output = nil
        sessionID = nil
    }

    private func send(type: String) throws {
        guard isStarted, let input, let sessionID else {
            throw BrowserSidecarError.unavailable
        }
        let command: [String: Any] = [
            "id": UUID().uuidString,
            "version": Self.protocolVersion,
            "session_id": sessionID,
            "deadline_ms": Int(Date().addingTimeInterval(Self.commandTimeout).timeIntervalSince1970 * 1_000),
            "type": type,
        ]
        let data = try JSONSerialization.data(withJSONObject: command)
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))
    }

    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard
                let response = try? JSONDecoder().decode(BrowserSidecarResponse.self, from: line),
                response.version == Self.protocolVersion,
                response.sessionID == sessionID
            else {
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
