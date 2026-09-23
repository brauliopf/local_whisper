import Foundation

nonisolated enum OpenAIAPI: Sendable {
    static let responses = URL(string: "https://api.openai.com/v1/responses")

    struct ErrorResponse: Decodable, Sendable {
        var error: Payload

        struct Payload: Decodable {
            var message: String
        }
    }
}
