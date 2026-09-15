import Foundation
import Darwin

nonisolated struct BrowserConfiguration: Codable, Sendable, Equatable {
    var initialURL: URL
    var allowedOrigins: [String]
    var artifactDirectory: URL
}

nonisolated struct BrowserTableResult: Codable, Sendable, Equatable {
    var type: String
    var columns: [String]
    var rows: [[String]]
    var notes: [String]
}

nonisolated struct BrowserArtifact: Codable, Sendable, Equatable {
    var path: String
    var mimeType: String
    var label: String
}

nonisolated struct BrowserState: Codable, Sendable, Equatable {
    var url: String
    var title: String
}

nonisolated struct BrowserResultError: Codable, Sendable, Equatable {
    var kind: String
    var message: String
}

nonisolated struct BrowserExecutorResult: Codable, Sendable, Equatable {
    var ok: Bool
    var value: BrowserTableResult?
    var text: [String]?
    var artifacts: [BrowserArtifact]?
    var browser: BrowserState
    var error: BrowserResultError?
}

nonisolated struct BrowserSessionInfo: Codable, Sendable, Equatable {
    var url: String
    var title: String
}

nonisolated enum BrowserExecutorError: LocalizedError, Sendable {
    case nodeNotFound(URL)
    case executorNotFound(URL)
    case processLaunchFailed(String)
    case processExited
    case protocolError(String)
    case timeout(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .nodeNotFound(let url):
            return "Node.js was not found at \(url.path)."
        case .executorNotFound(let url):
            return "The browser executor was not found at \(url.path)."
        case .processLaunchFailed(let message):
            return "Couldn't launch the browser executor: \(message)"
        case .processExited:
            return "The browser executor stopped unexpectedly."
        case .protocolError(let message):
            return "Browser executor protocol error: \(message)"
        case .timeout(let operation):
            return "The browser executor timed out during \(operation)."
        case .cancelled:
            return "The browser executor was cancelled."
        }
    }
}

nonisolated protocol BrowserExecuting: Sendable {
    func start(configuration: BrowserConfiguration) async throws -> BrowserSessionInfo
    func execute(module: String) async throws -> BrowserExecutorResult
    func stop() async
}

actor NodeBrowserExecutor: BrowserExecuting {
    private struct WireResponse {
        var id: Int
        var result: Data?
        var error: String?
    }

    private let nodeURL: URL
    private let executorURL: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pendingID: Int?
    private var pending: CheckedContinuation<WireResponse, Error>?

    init(nodeURL: URL, executorURL: URL) {
        self.nodeURL = nodeURL
        self.executorURL = executorURL
    }

    func start(configuration: BrowserConfiguration) async throws -> BrowserSessionInfo {
        guard process == nil else {
            throw BrowserExecutorError.processLaunchFailed("This adapter instance already has a process.")
        }
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path) else {
            throw BrowserExecutorError.nodeNotFound(nodeURL)
        }
        guard FileManager.default.fileExists(atPath: executorURL.path) else {
            throw BrowserExecutorError.executorNotFound(executorURL)
        }

        let process = Process()
        process.executableURL = nodeURL
        process.arguments = [executorURL.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] _ in
            Task { await self?.processDidExit() }
        }

        do {
            try process.run()
        } catch {
            throw BrowserExecutorError.processLaunchFailed(error.localizedDescription)
        }

        self.process = process
        self.input = stdin.fileHandleForWriting
        self.output = stdout.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receive(data) }
        }

        do {
            let response = try await send(
                method: "session.start",
                params: [
                    "initialURL": configuration.initialURL.absoluteString,
                    "allowedOrigins": configuration.allowedOrigins,
                    "artifactDirectory": configuration.artifactDirectory.path,
                ],
                timeout: 30
            )
            return try decode(BrowserSessionInfo.self, from: response)
        } catch {
            await stop()
            throw error
        }
    }

    func execute(module: String) async throws -> BrowserExecutorResult {
        do {
            let response = try await send(
                method: "script.execute",
                params: ["module": module],
                timeout: 65
            )
            return try decode(BrowserExecutorResult.self, from: response)
        } catch {
            if Task.isCancelled || error is BrowserExecutorError {
                await stop()
            }
            throw error
        }
    }

    func stop() async {
        guard let process else { return }
        completePending(with: .failure(BrowserExecutorError.cancelled))

        if process.isRunning {
            _ = try? await send(method: "session.stop", params: [:], timeout: 1)
            await waitForExit(process, timeout: 0.25)
        }
        if process.isRunning {
            process.terminate()
            await waitForExit(process, timeout: 0.25)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            await waitForExit(process, timeout: 0.25)
        }
        cleanup()
    }

    private func send(method: String, params: [String: Any], timeout: TimeInterval) async throws -> WireResponse {
        guard let input, process?.isRunning == true else {
            throw BrowserExecutorError.processExited
        }
        guard pending == nil else {
            throw BrowserExecutorError.protocolError("A request is already in flight.")
        }

        nextID += 1
        let id = nextID
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw BrowserExecutorError.protocolError("Couldn't encode \(method): \(error.localizedDescription)")
        }

        let timer = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.completePending(with: .failure(BrowserExecutorError.timeout(method)))
            } catch {
                // The response arrived before the timeout.
            }
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingID = id
                pending = continuation
                input.write(data)
                input.write(Data([0x0A]))
            }
        } onCancel: {
            Task { await self.completePending(with: .failure(BrowserExecutorError.cancelled)) }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from response: WireResponse) throws -> T {
        if let error = response.error {
            throw BrowserExecutorError.protocolError(error)
        }
        guard let result = response.result else {
            throw BrowserExecutorError.protocolError("Response did not contain a result.")
        }
        do {
            return try JSONDecoder().decode(type, from: result)
        } catch {
            throw BrowserExecutorError.protocolError("Couldn't decode response: \(error.localizedDescription)")
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let response = try? decodeWireResponse(Data(line)) else {
                log("Ignored malformed stdout line from executor.")
                continue
            }
            guard let pendingID, response.id == pendingID else {
                continue
            }
            completePending(with: .success(response))
        }
    }

    private func decodeWireResponse(_ data: Data) throws -> WireResponse? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int else {
            return nil
        }

        var resultData: Data?
        if let result = object["result"] {
            resultData = try JSONSerialization.data(withJSONObject: result)
        }
        let error = (object["error"] as? [String: Any])?["message"] as? String
        return WireResponse(id: id, result: resultData, error: error)
    }

    private func completePending(with result: Result<WireResponse, Error>) {
        guard let pending else { return }
        self.pending = nil
        pendingID = nil
        switch result {
        case .success(let response): pending.resume(returning: response)
        case .failure(let error): pending.resume(throwing: error)
        }
    }

    private func processDidExit() {
        completePending(with: .failure(BrowserExecutorError.processExited))
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func cleanup() {
        output?.readabilityHandler = nil
        input?.closeFile()
        output?.closeFile()
        input = nil
        output = nil
        process = nil
        buffer.removeAll(keepingCapacity: false)
        pendingID = nil
        pending = nil
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[browser-adapter] \(message)\n".utf8))
    }
}
