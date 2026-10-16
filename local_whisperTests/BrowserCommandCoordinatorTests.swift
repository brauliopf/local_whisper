import XCTest
@testable import local_whisper

@MainActor
final class BrowserCommandCoordinatorTests: XCTestCase {
    func testReadyRunningSessionCanStartRecording() {
        XCTAssertTrue(
            BrowserCommandCoordinator.canStartRecording(
                browserState: .running,
                commandState: .ready,
                browserIsBusy: false
            )
        )
    }

    func testBusyCommandRejectsAnotherRecording() {
        XCTAssertFalse(
            BrowserCommandCoordinator.canStartRecording(
                browserState: .running,
                commandState: .ready,
                browserIsBusy: true
            )
        )
        XCTAssertFalse(
            BrowserCommandCoordinator.canStartRecording(
                browserState: .running,
                commandState: .planning,
                browserIsBusy: false
            )
        )
    }

    func testPausedSessionCannotStartRecording() {
        XCTAssertFalse(
            BrowserCommandCoordinator.canStartRecording(
                browserState: .pausedForUser,
                commandState: .ready,
                browserIsBusy: false
            )
        )
    }

    func testCommandStatesRemainDistinct() {
        XCTAssertNotEqual(BrowserCommandCoordinator.State.recording, .transcribing)
        XCTAssertNotEqual(BrowserCommandCoordinator.State.planning, .executing)
        XCTAssertNotEqual(BrowserCommandCoordinator.State.ready, .stopped)
    }
}
