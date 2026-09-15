import Foundation

nonisolated struct OpenAITransport: Sendable {
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    func send(_ request: URLRequest, failurePrefix: String = "Couldn't fetch a message") async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenAIError.network(Self.networkMessage(for: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? decoder.decode(OpenAIAPI.ErrorResponse.self, from: data) {
                throw OpenAIError.apiError("\(failurePrefix) — \(apiError.error.message)")
            }
            throw OpenAIError.apiError("\(failurePrefix) — check your API key.")
        }
        return data
    }

    private static func networkMessage(for error: Error) -> String {
        let code = (error as? URLError)?.code
        switch code {
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            return "Couldn't reach OpenAI. Check your internet connection."
        case .notConnectedToInternet, .networkConnectionLost:
            return "No internet connection."
        case .timedOut:
            return "OpenAI timed out — try again."
        default:
            return "Couldn't fetch a message — \(error.localizedDescription)"
        }
    }
}
