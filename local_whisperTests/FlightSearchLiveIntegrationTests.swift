import Foundation
import XCTest
@testable import local_whisper

@MainActor
final class FlightSearchLiveIntegrationTests: XCTestCase {
    func testLiveFlightSearchWorkflowAgainstGoogleFlights() async throws {
        guard let nodePath = ProcessInfo.processInfo.environment["LOCAL_WHISPER_NODE"], !nodePath.isEmpty else {
            throw XCTSkip("Set LOCAL_WHISPER_NODE to run the live flight workflow test.")
        }
        guard let executorPath = ProcessInfo.processInfo.environment["LOCAL_WHISPER_EXECUTOR"], !executorPath.isEmpty else {
            throw XCTSkip("Set LOCAL_WHISPER_EXECUTOR to run the live flight workflow test.")
        }
        guard FileManager.default.isExecutableFile(atPath: nodePath) else {
            throw XCTSkip("LOCAL_WHISPER_NODE is not executable: \(nodePath)")
        }
        guard FileManager.default.fileExists(atPath: executorPath) else {
            throw XCTSkip("LOCAL_WHISPER_EXECUTOR does not exist: \(executorPath)")
        }
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty else {
            throw XCTSkip("Set OPENAI_API_KEY to run the live flight workflow test.")
        }

        let workflow = FlightSearchWorkflow.live(keychain: EnvironmentKeychain(apiKey: apiKey))
        workflow.task = """
        Use the execute_playwright tool exactly once. On the current Google Flights page, use only Playwright's page API and return a generic table with one column named Title and one row containing await page.title(). Do not use document, window, or browser DOM APIs. After the tool returns, answer with only the page title.
        """
        workflow.start()

        for _ in 0..<1_800 {
            if case .completed(let result) = workflow.state {
                XCTAssertFalse(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                return
            }
            if case .failed(let message) = workflow.state {
                XCTFail("Live flight workflow failed: \(message)")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTFail("Timed out waiting for the live flight workflow.")
    }
}

private struct EnvironmentKeychain: Keychaining {
    let apiKey: String

    var hasAPIKey: Bool { !apiKey.isEmpty }
    func loadAPIKey() -> String? { apiKey }
    func saveAPIKey(_ key: String) -> Bool { true }
}
