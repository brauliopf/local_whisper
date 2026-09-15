import Foundation
import XCTest
@testable import local_whisper

final class BrowserExecutorTests: XCTestCase {
    func testBrowserConfigurationRoundTrips() throws {
        let configuration = BrowserConfiguration(
            initialURL: URL(string: "https://www.google.com/travel/flights")!,
            allowedOrigins: ["https://www.google.com"],
            artifactDirectory: URL(fileURLWithPath: "/tmp/browser-artifacts")
        )

        let decoded = try JSONDecoder().decode(
            BrowserConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )

        XCTAssertEqual(decoded, configuration)
    }

    func testExecutorResultDecodesScriptFailure() throws {
        let data = Data(#"{"ok":false,"error":{"kind":"script_error","message":"Element not found"},"browser":{"url":"https://www.google.com/travel/flights","title":"Google Flights"}}"#.utf8)
        let result = try JSONDecoder().decode(BrowserExecutorResult.self, from: data)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error?.kind, "script_error")
    }

    func testRealNodeExecutorAgainstFixture() async throws {
        guard let nodePath = ProcessInfo.processInfo.environment["LOCAL_WHISPER_NODE"],
              let executorPath = ProcessInfo.processInfo.environment["LOCAL_WHISPER_EXECUTOR"] else {
            throw XCTSkip("Set LOCAL_WHISPER_NODE and LOCAL_WHISPER_EXECUTOR to run the Node integration test.")
        }

        let executor = NodeBrowserExecutor(
            nodeURL: URL(fileURLWithPath: nodePath),
            executorURL: URL(fileURLWithPath: executorPath)
        )
        let fixture = URL(string: "data:text/html,%3Ch1%3ESwift%20adapter%20fixture%3C%2Fh1%3E")!
        let configuration = BrowserConfiguration(
            initialURL: fixture,
            allowedOrigins: ["null"],
            artifactDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("browser-adapter-\(UUID().uuidString)")
        )

        do {
            _ = try await executor.start(configuration: configuration)
            let result = try await executor.execute(module: """
                module.exports = async ({ page }) => ({
                    type: 'table',
                    columns: ['Heading'],
                    rows: [[await page.locator('h1').textContent()]],
                    notes: []
                });
                """)
            XCTAssertTrue(result.ok)
            XCTAssertEqual(result.value?.rows, [["Swift adapter fixture"]])
            await executor.stop()
        } catch {
            await executor.stop()
            throw error
        }
    }
}
