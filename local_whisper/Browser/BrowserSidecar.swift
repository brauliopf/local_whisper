import Foundation

@MainActor
final class BrowserSidecar {
    var onState: ((String, String?) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()

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
            Task { @MainActor in
                guard self?.process === process else { return }
                self?.process = nil
                self?.input = nil
                self?.onState?("stopped", "Browser agent exited with status \(process.terminationStatus).")
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.consume(data)
            }
        }

        try process.run()
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        send(type: "start", profilePath: profilePath.path)
    }

    func stop() {
        guard let process else { return }
        send(type: "stop")
        process.terminate()
        self.process = nil
        input = nil
    }

    private func send(type: String, profilePath: String? = nil) {
        guard let input else { return }
        var request: [String: String] = [
            "id": UUID().uuidString,
            "type": type,
        ]
        if let profilePath { request["profilePath"] = profilePath }
        guard
            let data = try? JSONSerialization.data(withJSONObject: request),
            var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        try? input.write(contentsOf: Data(line.utf8))
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard
                let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let type = response["type"] as? String
            else { continue }
            onState?(response["state"] as? String ?? type, response["message"] as? String)
        }
    }

    private func scriptURL() throws -> URL {
        if let configured = ProcessInfo.processInfo.environment["LOCAL_WHISPER_BROWSER_AGENT"] {
            return URL(fileURLWithPath: configured)
        }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("browser-agent/dist/main.js")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "BrowserAgent", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Build browser-agent before starting the browser."
            ])
        }
        return url
    }
}
