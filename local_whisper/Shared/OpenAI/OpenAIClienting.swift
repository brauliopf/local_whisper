import Foundation

nonisolated enum OpenAIError: LocalizedError, Sendable {
    case invalidResponse
    case apiError(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Couldn't fetch a message — try again."
        case .apiError(let message):
            return message
        case .network(let message):
            return message
        }
    }
}

nonisolated protocol OpenAIResponsesClienting: Sendable {
    func createResponse(
        _ request: OpenAIResponsesAPI.Request,
        apiKey: String,
        timeout: TimeInterval
    ) async throws -> OpenAIResponsesAPI.Response
}

nonisolated protocol Keychaining: Sendable {
    var hasServiceToken: Bool { get }
    func loadServiceToken() -> String?
    @discardableResult func saveServiceToken(_ token: String) -> Bool
}
