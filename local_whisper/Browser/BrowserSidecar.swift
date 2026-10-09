import Foundation

@MainActor
final class BrowserSidecar {
    var onState: ((String, String?) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]

    var isRunning: Bool { process?.isRunning == true }

    func start(profilePath: URL) throws {
        guard !isRunning else { return }
        let script = try scriptURL()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self, self.process === process else { return }
                self.process = nil
                self.input = nil
                self.onState?("stopped", "Browser agent exited with status \(process.terminationStatus).")
                self.failPending("Browser agent exited")
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consume(data)
            }
        }

        try process.run()
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        Task { [weak self] in
            _ = try? await self?.request(type: "start", values: ["profilePath": profilePath.path])
        }
    }

    func stop() {
        guard let process else { return }
        send(type: "stop")
        process.terminate()
        self.process = nil
        input = nil
        failPending("Browser session stopped")
    }

    func navigate(_ url: String) async throws -> [String: Any] {
        try await request(type: "navigate", values: ["url": url])
    }

    func inspect() async throws -> [String: Any] {
        try await request(type: "inspect")
    }

    func execute(_ action: [String: Any]) async throws -> [String: Any] {
        try await request(type: "execute", values: ["action": action])
    }

    private func request(type: String, values: [String: Any] = [:]) async throws -> [String: Any] {
        guard process?.isRunning == true else { throw browserError("Browser agent is not running") }
        let id = UUID().uuidString
        var request: [String: Any] = ["id": id, "type": type]
        values.forEach { request[$0.key] = $0.value }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(request)
        }
    }

    private func send(type: String) {
        send(["id": UUID().uuidString, "type": type])
    }

    private func send(_ request: [String: Any]) {
        guard let input,
              let data = try? JSONSerialization.data(withJSONObject: request),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        try? input.write(contentsOf: Data(line.utf8))
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
            guard let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = response["type"] as? String
            else { continue }
            if let id = response["id"] as? String, let continuation = pending.removeValue(forKey: id) {
                if type == "error" {
                    continuation.resume(throwing: browserError(response["message"] as? String ?? "Browser operation failed"))
                } else {
                    continuation.resume(returning: response)
                }
            }
            if let state = response["state"] as? String {
                onState?(state, response["message"] as? String)
            }
        }
    }

    private func failPending(_ message: String) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: browserError(message)) }
    }

    private func browserError(_ message: String) -> NSError {
        NSError(domain: "BrowserAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func scriptURL() throws -> URL {
        if let configured = ProcessInfo.processInfo.environment["LOCAL_WHISPER_BROWSER_AGENT"] {
            return URL(fileURLWithPath: configured)
        }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("browser-agent/dist/main.js")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw browserError("Build browser-agent before starting the browser")
        }
        return url
    }
}
