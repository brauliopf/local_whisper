import Foundation

actor OpenAIResponsesClient: OpenAIResponsesClienting {
    private let transport: OpenAITransport
    private let endpoint: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(transport: OpenAITransport = OpenAITransport(), endpoint: URL? = OpenAIAPI.responses) {
        self.transport = transport
        self.endpoint = endpoint
    }

    func createResponse(
        _ body: OpenAIResponsesAPI.Request,
        apiKey: String,
        timeout: TimeInterval = 120
    ) async throws -> OpenAIResponsesAPI.Response {
        guard let endpoint else { throw OpenAIError.invalidResponse }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let data = try await transport.send(
            request,
            failurePrefix: "Couldn't continue the Responses conversation"
        )
        return try decoder.decode(OpenAIResponsesAPI.Response.self, from: data)
    }
}
