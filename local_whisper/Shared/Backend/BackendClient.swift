import Foundation

nonisolated enum BackendError: LocalizedError, Sendable {
    case missingServiceToken
    case invalidResponse
    case apiError(code: String, message: String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingServiceToken:
            return "Add the backend service token in Settings."
        case .invalidResponse:
            return "The backend returned an invalid response."
        case .apiError(_, let message):
            return message
        case .network(let message):
            return message
        }
    }
}

nonisolated struct BackendImageTextResponse: Decodable, Sendable {
    let text: String?
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case text
        case requestID = "request_id"
    }
}

nonisolated protocol BackendClienting: Sendable {
    func extractText(fromJPEG data: Data, serviceToken: String) async throws -> String?
    func fetchEncouragement(serviceToken: String) async throws -> String
    func transcribeAudio(at fileURL: URL, serviceToken: String) async throws -> String
}

nonisolated enum BackendConfiguration {
    static let fallbackURL = URL(string: "https://local-whisper-api-24n67dikla-uw.a.run.app")!

    static var baseURL: URL {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "BACKEND_BASE_URL") as? String,
            let url = URL(string: value),
            url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost"
        else {
            return fallbackURL
        }
        return url
    }
}

actor BackendClient: BackendClienting {
    private let session: URLSession
    private let baseURL: URL
    private let decoder = JSONDecoder()

    init(
        session: URLSession = .shared,
        baseURL: URL = BackendConfiguration.baseURL
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    func extractText(fromJPEG data: Data, serviceToken: String) async throws -> String? {
        guard !serviceToken.isEmpty else { throw BackendError.missingServiceToken }
        let boundary = UUID().uuidString
        var request = makeRequest(path: "image-text", serviceToken: serviceToken)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            data: data,
            boundary: boundary,
            fieldName: "image",
            filename: "screenshot.jpg",
            contentType: "image/jpeg"
        )

        let response: BackendImageTextResponse = try await send(request)
        return response.text
    }

    func fetchEncouragement(serviceToken: String) async throws -> String {
        guard !serviceToken.isEmpty else { throw BackendError.missingServiceToken }
        var request = makeRequest(path: "encouragements", serviceToken: serviceToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let response: BackendImageTextResponse = try await send(request)
        guard let text = response.text, !text.isEmpty else { throw BackendError.invalidResponse }
        return text
    }

    func transcribeAudio(at fileURL: URL, serviceToken: String) async throws -> String {
        guard !serviceToken.isEmpty else { throw BackendError.missingServiceToken }
        let audio: Data
        do {
            audio = try Data(contentsOf: fileURL)
        } catch {
            throw BackendError.invalidResponse
        }

        let boundary = UUID().uuidString
        var request = makeRequest(path: "transcriptions", serviceToken: serviceToken)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            data: audio,
            boundary: boundary,
            fieldName: "audio",
            filename: fileURL.lastPathComponent,
            contentType: "audio/mp4"
        )

        let response: BackendImageTextResponse = try await send(request)
        return response.text ?? ""
    }

    private func makeRequest(path: String, serviceToken: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(serviceToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BackendError.network(Self.networkMessage(for: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? decoder.decode(BackendAPI.ErrorResponse.self, from: data) {
                throw BackendError.apiError(code: apiError.error.code, message: apiError.error.message)
            }
            throw BackendError.apiError(code: "http_\(http.statusCode)", message: "The backend request failed.")
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw BackendError.invalidResponse
        }
    }

    private static func multipartBody(
        data: Data,
        boundary: String,
        fieldName: String,
        filename: String,
        contentType: String
    ) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func networkMessage(for error: Error) -> String {
        switch (error as? URLError)?.code {
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            return "Couldn't reach the backend. Check your connection."
        case .notConnectedToInternet, .networkConnectionLost:
            return "No internet connection."
        case .timedOut:
            return "The backend timed out — try again."
        default:
            return "Couldn't reach the backend — \(error.localizedDescription)"
        }
    }
}

nonisolated enum BackendAPI: Sendable {
    struct ErrorResponse: Decodable, Sendable {
        let error: Payload

        struct Payload: Decodable, Sendable {
            let code: String
            let message: String
        }
    }
}
