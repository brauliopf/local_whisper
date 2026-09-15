import Foundation
import XCTest
@testable import local_whisper

@MainActor
final class ComputerUseLiveIntegrationTests: XCTestCase {
    func testLiveOpenAIComputerUseAgainstLocalFixture() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty else {
            throw XCTSkip("Set OPENAI_API_KEY to run the live computer-use test.")
        }
        guard let nodePath = ProcessInfo.processInfo.environment["LOCAL_WHISPER_NODE"], !nodePath.isEmpty else {
            throw XCTSkip("Set LOCAL_WHISPER_NODE to run the live computer-use test.")
        }
        guard let executorPath = ProcessInfo.processInfo.environment["LOCAL_WHISPER_EXECUTOR"], !executorPath.isEmpty else {
            throw XCTSkip("Set LOCAL_WHISPER_EXECUTOR to run the live computer-use test.")
        }
        guard FileManager.default.isExecutableFile(atPath: nodePath) else {
            throw XCTSkip("LOCAL_WHISPER_NODE is not executable: \(nodePath)")
        }
        guard FileManager.default.fileExists(atPath: executorPath) else {
            throw XCTSkip("LOCAL_WHISPER_EXECUTOR does not exist: \(executorPath)")
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
        let html = "<html><body><h1>Live computer-use fixture</h1></body></html>"
        let initialURL = URL(string: "data:text/html;base64,\(Data(html.utf8).base64EncodedString())")!

        let result = try await coordinator.run(
            task: """
            Use the execute_playwright tool exactly once. The generated module must use this contract: module.exports = async ({ page }) => ({ type: "table", columns: ["Heading"], rows: [[await page.locator("h1").innerText()]], notes: [] }); Use Playwright's page API only; do not use document, window, or browser DOM APIs. Read the text of the h1 element on the current page and return it as a generic table with one column named Heading. After the tool returns, answer with only the heading text.
            """,
            model: model,
            apiKey: apiKey,
            browserConfiguration: BrowserConfiguration(
                initialURL: initialURL,
                allowedOrigins: ["null"],
                artifactDirectory: artifactDirectory
            )
        )

        XCTAssertTrue(
            result.localizedCaseInsensitiveContains("Live computer-use fixture"),
            "Unexpected live Responses result: \(result)"
        )
    }
}
