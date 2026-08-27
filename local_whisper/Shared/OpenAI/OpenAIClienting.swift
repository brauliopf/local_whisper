import Foundation

nonisolated enum OpenAIError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidResponse
    case apiError(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenAI API key in Settings."
        case .invalidResponse:
            return "Couldn't fetch a message — try again."
        case .apiError(let message):
            return message
        case .network(let message):
            return message
        }
    }
}

nonisolated protocol OpenAIClienting: Sendable {
    func listModels(apiKey: String) async throws -> [String]
    func fetchEncouragement(apiKey: String, model: String) async throws -> String
    func transcribeAudio(at fileURL: URL, apiKey: String, model: String) async throws -> String
    func extractText(fromJPEG data: Data, apiKey: String, model: String) async throws -> String?
}

nonisolated protocol Keychaining: Sendable {
    var hasAPIKey: Bool { get }
    func loadAPIKey() -> String?
    @discardableResult func saveAPIKey(_ key: String) -> Bool
}
