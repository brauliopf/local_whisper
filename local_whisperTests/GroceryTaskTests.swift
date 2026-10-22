import XCTest
@testable import local_whisper

@MainActor
final class GroceryTaskTests: XCTestCase {
    func testEmptyRequestFailsWithoutStartingSearch() {
        let task = GroceryTaskCoordinator()
        task.start(request: "  ", signedIn: true)
        XCTAssertEqual(task.phase, .failed("Enter one grocery item to search for."))
    }

    func testUnauthenticatedTaskWaitsForSignIn() {
        let task = GroceryTaskCoordinator()
        task.start(request: "organic apples", signedIn: false)
        XCTAssertEqual(task.phase, .awaitingSignIn)
        task.signInCompleted()
        XCTAssertEqual(task.phase, .searching)
    }

    func testClearCandidateIsAddedAndVerified() {
        let task = GroceryTaskCoordinator()
        task.start(request: "organic apples", signedIn: true)
        let candidate = GroceryCandidate(id: "apple-1", title: "Organic apples", brand: nil, size: nil, available: true)
        task.receiveCandidates([candidate])
        XCTAssertEqual(task.phase, .adding(candidateID: "apple-1"))
        task.addStarted()
        task.cartVerified(candidateID: "apple-1")
        XCTAssertEqual(task.phase, .completed(candidateID: "apple-1"))
    }

    func testAmbiguousCandidatesRequireChoice() {
        let task = GroceryTaskCoordinator()
        task.start(request: "coffee", signedIn: true)
        let first = GroceryCandidate(id: "coffee-1", title: "Ground coffee", brand: nil, size: nil, available: true)
        let second = GroceryCandidate(id: "coffee-2", title: "Whole bean coffee", brand: nil, size: nil, available: true)
        task.receiveCandidates([first, second])
        XCTAssertEqual(task.phase, .awaitingCandidate([first, second]))
        task.chooseCandidate(second)
        XCTAssertEqual(task.phase, .adding(candidateID: "coffee-2"))
    }

    func testNoMatchDoesNotAdd() {
        let task = GroceryTaskCoordinator()
        task.start(request: "rare item", signedIn: true)
        task.receiveCandidates([])
        XCTAssertEqual(task.phase, .noMatch)
        XCTAssertEqual(task.resultMessage, "No matching grocery item was found.")
    }
}
