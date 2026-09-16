import Foundation
import XCTest
@testable import local_whisper

@MainActor
final class ComputerUseLiveIntegrationTests: XCTestCase {
    func testLiveOpenAIComputerUseAgainstLocalFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["OPENAI_API_KEY"] ?? KeychainStore().loadAPIKey(), !apiKey.isEmpty else {
            try skip("Set OPENAI_API_KEY or save an API key in the app settings.")
        }
        let nodePath = environment["LOCAL_WHISPER_NODE"] ?? "/opt/homebrew/bin/node"
        let executorPath = environment["LOCAL_WHISPER_EXECUTOR"] ??
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("computer-use-executor/dist/index.js").path
        guard FileManager.default.isExecutableFile(atPath: nodePath) else {
            try skip("LOCAL_WHISPER_NODE is not executable: \(nodePath)")
        }
        guard FileManager.default.fileExists(atPath: executorPath) else {
            try skip("LOCAL_WHISPER_EXECUTOR does not exist: \(executorPath)")
        }

        let model = ProcessInfo.processInfo.environment["OPENAI_RESPONSES_MODEL"] ?? "gpt-4.1-mini"
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-whisper-live-\(UUID().uuidString)")
        let browser = NodeBrowserExecutor(
            nodeURL: URL(fileURLWithPath: nodePath),
            executorURL: URL(fileURLWithPath: executorPath)
        )
        let coordinator = ComputerUseCoordinator(
            responses: OpenAIResponsesClient(),
            browser: browser,
            maxRounds: 3,
            responseTimeout: 120
        )
        let configuredURL = ProcessInfo.processInfo.environment["COMPUTER_USE_TEST_URL"]
        let initialURL: URL
        let allowedOrigins: [String]
        let task: String
        let expectedText: String?

        if let configuredURL {
            guard let url = URL(string: configuredURL),
                  let scheme = url.scheme,
                  let host = url.host else {
                throw XCTSkip("COMPUTER_USE_TEST_URL must be a valid URL.")
            }
            let origin = "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
            initialURL = url
            allowedOrigins = [origin]
            task = ProcessInfo.processInfo.environment["COMPUTER_USE_TEST_TASK"] ?? "Read the title and a concise description from the current page, then report the observations."
            expectedText = nil
        } else {
            let html = "<html><body><h1>Live computer-use fixture</h1></body></html>"
            initialURL = URL(string: "data:text/html;base64,\(Data(html.utf8).base64EncodedString())")!
            allowedOrigins = ["null"]
            task = "Read the text of the h1 element on the current page and report the observation."
            expectedText = "Live computer-use fixture"
        }

        let result = try await coordinator.run(
            task: task,
            model: model,
            apiKey: apiKey,
            browserConfiguration: BrowserConfiguration(
                initialURL: initialURL,
                allowedOrigins: allowedOrigins,
                artifactDirectory: artifactDirectory
            )
        )

        print("Computer-use result:\n\(result)")
        if let outputPath = environment["COMPUTER_USE_OUTPUT_PATH"] {
            try? result.write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
        }
        XCTAssertFalse(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let expectedText {
            XCTAssertTrue(
                result.localizedCaseInsensitiveContains(expectedText),
                "Unexpected live Responses result: \(result)"
            )
        }
    }

    private func skip(_ message: String) throws -> Never {
        FileHandle.standardError.write(Data("Skipping live computer-use test: \(message)\n".utf8))
        throw XCTSkip(message)
    }
}
