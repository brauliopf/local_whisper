import Foundation
import Observation

struct GroceryCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let brand: String?
    let size: String?
    let available: Bool
}

enum GroceryTaskPhase: Equatable, Sendable {
    case idle
    case searching
    case awaitingSignIn
    case awaitingCandidate([GroceryCandidate])
    case adding(candidateID: String)
    case verifying(candidateID: String)
    case completed(candidateID: String)
    case noMatch
    case failed(String)
    case cancelled
}

@MainActor
@Observable
final class GroceryTaskCoordinator {
    private(set) var phase: GroceryTaskPhase = .idle
    private(set) var request = ""
    private(set) var selectedCandidateID: String?
    private(set) var resultMessage: String?

    func start(request: String, signedIn: Bool) {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .failed("Enter one grocery item to search for.")
            resultMessage = phaseMessage
            return
        }
        self.request = trimmed
        selectedCandidateID = nil
        resultMessage = nil
        phase = signedIn ? .searching : .awaitingSignIn
    }

    func signInCompleted() {
        guard phase == .awaitingSignIn else { return }
        phase = .searching
    }

    func receiveCandidates(_ candidates: [GroceryCandidate]) {
        guard phase == .searching else { return }
        let available = candidates.filter(\.available)
        switch available.count {
        case 0: phase = .noMatch
        case 1:
            selectedCandidateID = available[0].id
            phase = .adding(candidateID: available[0].id)
        default:
            phase = .awaitingCandidate(available)
        }
        resultMessage = phaseMessage
    }

    func chooseCandidate(_ candidate: GroceryCandidate) {
        guard case .awaitingCandidate(let candidates) = phase,
              candidates.contains(candidate), candidate.available else { return }
        selectedCandidateID = candidate.id
        phase = .adding(candidateID: candidate.id)
        resultMessage = nil
    }

    func addStarted() {
        guard case .adding(let candidateID) = phase else { return }
        phase = .verifying(candidateID: candidateID)
    }

    func cartVerified(candidateID: String) {
        guard case .verifying(let expectedID) = phase, expectedID == candidateID else { return }
        phase = .completed(candidateID: candidateID)
        resultMessage = "Added the requested item to the cart."
    }

    func noMatch() {
        guard !phase.isTerminal else { return }
        phase = .noMatch
        resultMessage = phaseMessage
    }

    func fail(_ message: String) {
        guard !phase.isTerminal else { return }
        phase = .failed(message)
        resultMessage = message
    }

    func cancel() {
        guard !phase.isTerminal else { return }
        phase = .cancelled
        resultMessage = "Grocery task cancelled."
    }

    private var phaseMessage: String {
        switch phase {
        case .noMatch: return "No matching grocery item was found."
        case .failed(let message): return message
        case .completed: return "Added the requested item to the cart."
        default: return ""
        }
    }
}

private extension GroceryTaskPhase {
    var isTerminal: Bool {
        switch self {
        case .completed, .noMatch, .failed, .cancelled: return true
        default: return false
        }
    }
}
