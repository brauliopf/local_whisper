import XCTest
@testable import local_whisper

@MainActor
final class FlightSearchWorkflowTests: XCTestCase {
    func testStartPublishesResult() async throws {
        let workflow = FlightSearchWorkflow { task in
            task == "Find SFO to JFK" ? "Three flights found." : "Unexpected task"
        }
        workflow.task = "Find SFO to JFK"

        workflow.start()
        try await waitUntil { workflow.state == .completed("Three flights found.") }

        XCTAssertEqual(workflow.state, .completed("Three flights found."))
    }

    func testEmptyTaskFailsWithoutRunning() {
        let workflow = FlightSearchWorkflow { _ in
            XCTFail("The runner should not be called")
            return ""
        }
        workflow.task = "   "

        workflow.start()

        XCTAssertEqual(workflow.state, .failed("Describe the flight research you want to run."))
    }

    func testRunnerFailureIsPublished() async throws {
        let workflow = FlightSearchWorkflow { _ in
            throw TestError.failed
        }

        workflow.start()
        try await waitUntil {
            if case .failed = workflow.state { return true }
            return false
        }

        XCTAssertEqual(workflow.state, .failed("The test runner failed."))
    }

    func testCancelReturnsToIdle() async throws {
        let workflow = FlightSearchWorkflow { _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return "Should not finish"
        }

        workflow.start()
        try await waitUntil { workflow.state == .running }
        workflow.cancel()

        XCTAssertEqual(workflow.state, .idle)
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool
    ) async throws {
        for _ in 0..<50 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for workflow state")
    }
}

private enum TestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "The test runner failed."
    }
}
