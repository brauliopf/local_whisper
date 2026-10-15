import CryptoKit
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
    private var pending: [String: Task<Void, Never>] = [:]

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
                guard self?.sessionID == sessionID else { return }
                self?.receive(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.process === process, self.sessionID == sessionID else { return }
                self.pending.values.forEach { $0.cancel() }
                self.pending.removeAll()
                self.process = nil
                self.input = nil
                self.output = nil
                self.sessionID = nil
                self.onExit?(process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            self.process = nil
            self.input = nil
            self.output = nil
            self.sessionID = nil
            throw BrowserSidecarError.launchFailed
        }
    }

    func startBrowser() throws {
        try send(type: "start")
    }

    func snapshot() throws {
        try send(type: "snapshot")
    }

    func execute(code: String, stateHash: String, policyVersion: String) throws {
        let codeHash = SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined()
        try send(type: "execute", fields: [
            "code": code,
            "code_hash": codeHash,
            "state_hash": stateHash,
            "policy_version": policyVersion,
        ])
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
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        process?.terminate()
        process = nil
        input = nil
        output = nil
        sessionID = nil
    }

    private func send(type: String, fields: [String: String] = [:]) throws {
        guard isStarted, let input, let sessionID else {
            throw BrowserSidecarError.unavailable
        }
        let id = UUID().uuidString
        pending[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.commandTimeout))
            guard !Task.isCancelled else { return }
            self?.timeout(id: id, sessionID: sessionID)
        }
        var command: [String: Any] = [
            "id": id,
            "version": Self.protocolVersion,
            "session_id": sessionID,
            "deadline_ms": Int(Date().addingTimeInterval(Self.commandTimeout).timeIntervalSince1970 * 1_000),
            "type": type,
        ]
        fields.forEach { command[$0.key] = $0.value }
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
                response.sessionID == sessionID,
                let request = pending.removeValue(forKey: response.id)
            else {
                continue
            }
            request.cancel()
            onResponse?(response)
        }
    }

    private func timeout(id: String, sessionID: String) {
        guard pending.removeValue(forKey: id) != nil else { return }
        onResponse?(BrowserSidecarResponse(
            id: id,
            version: Self.protocolVersion,
            sessionID: sessionID,
            ok: false,
            status: .running,
            snapshot: nil,
            error: "request_timeout"
        ))
    }

    private static func executableURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["BROWSER_SIDECAR_PATH"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.url(forResource: "browser-sidecar", withExtension: nil)
    }
}
