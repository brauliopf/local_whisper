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

nonisolated struct ComputerUseStepResponse: Decodable, Sendable, Equatable {
    let id: String
    let code: String
    let codeHash: String
    let browserStateHash: String
    let summary: String
    let risk: String
    let status: String
    let approvalExpiresAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id, code, summary, risk, status
        case codeHash = "code_hash"
        case browserStateHash = "browser_state_hash"
        case approvalExpiresAt = "approval_expires_at"
    }
}

nonisolated struct ComputerUseResponse: Decodable, Sendable, Equatable {
    let sessionID: String
    let status: String
    let done: Bool
    let message: String?
    let step: ComputerUseStepResponse?
    let guardrailReasons: [String]?

    enum CodingKeys: String, CodingKey {
        case status, done, message, step
        case sessionID = "session_id"
        case guardrailReasons = "guardrail_reasons"
    }
}

nonisolated protocol BackendClienting: Sendable {
    func extractText(fromJPEG data: Data, serviceToken: String) async throws -> String?
    func fetchEncouragement(serviceToken: String) async throws -> String
    func transcribeAudio(at fileURL: URL, serviceToken: String) async throws -> String
    func startComputerUse(instruction: String, initialURL: URL, allowedOrigins: [String], currentURL: String, currentTitle: String, serviceToken: String) async throws -> ComputerUseResponse
    func approveComputerUseStep(sessionID: String, stepID: String, codeHash: String, browserStateHash: String, serviceToken: String) async throws -> ComputerUseResponse
    func denyComputerUseStep(sessionID: String, stepID: String, serviceToken: String) async throws -> ComputerUseResponse
    func submitComputerUseResult(sessionID: String, stepID: String, resultJSON: Data, screenshot: Data, currentURL: String, currentTitle: String, serviceToken: String) async throws -> ComputerUseResponse
    func cancelComputerUse(sessionID: String, serviceToken: String) async throws
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

    func startComputerUse(instruction: String, initialURL: URL, allowedOrigins: [String], currentURL: String, currentTitle: String, serviceToken: String) async throws -> ComputerUseResponse {
        guard !serviceToken.isEmpty else { throw BackendError.missingServiceToken }
        var request = makeRequest(path: "computer-use/sessions", serviceToken: serviceToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "instruction": instruction,
            "initial_url": initialURL.absoluteString,
            "allowed_origins": allowedOrigins,
            "current_url": currentURL,
            "current_title": currentTitle,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            return try await send(request)
        } catch BackendError.apiError(let code, let message)
                    where code == "invalid_input" && message.localizedCaseInsensitiveContains("allowed origins") {
            // Older deployed backends reject the wildcard origin used by the new client.
            // Retry with the origins currently visible to the browser so read-only tasks
            // remain usable until the backend is redeployed.
            var compatibilityBody = body
            compatibilityBody["allowed_origins"] = Self.compatibilityOrigins(initialURL: initialURL, currentURL: currentURL)
            request.httpBody = try JSONSerialization.data(withJSONObject: compatibilityBody)
            return try await send(request)
        }
    }

    func approveComputerUseStep(sessionID: String, stepID: String, codeHash: String, browserStateHash: String, serviceToken: String) async throws -> ComputerUseResponse {
        guard !serviceToken.isEmpty else { throw BackendError.missingServiceToken }
        var request = makeRequest(path: "computer-use/sessions/\(sessionID)/steps/\(stepID)/approve", serviceToken: serviceToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code_hash": codeHash, "browser_state_hash": browserStateHash])
        return try await send(request)
    }

    func denyComputerUseStep(sessionID: String, stepID: String, serviceToken: String) async throws -> ComputerUseResponse {
        guard !serviceToken.isEmpty else { throw BackendError.missingServiceToken }
        var request = makeRequest(path: "computer-use/sessions/\(sessionID)/steps/\(stepID)/deny", serviceToken: serviceToken)
        request.httpMethod = "POST"
        return try await send(request)
    }

    func submitComputerUseResult(sessionID: String, stepID: String, resultJSON: Data, screenshot: Data, currentURL: String, currentTitle: String, serviceToken: String) async throws -> ComputerUseResponse {
        guard !serviceToken.isEmpty else { throw BackendError.missingServiceToken }
        let boundary = UUID().uuidString
        var request = makeRequest(path: "computer-use/sessions/\(sessionID)/steps/\(stepID)/result", serviceToken: serviceToken)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(parts: [
            (name: "screenshot", filename: "screenshot.png", contentType: "image/png", data: screenshot),
            (name: "result", filename: nil, contentType: "application/json", data: resultJSON),
            (name: "current_url", filename: nil, contentType: "text/plain", data: Data(currentURL.utf8)),
            (name: "current_title", filename: nil, contentType: "text/plain", data: Data(currentTitle.utf8)),
        ], boundary: boundary)
        return try await send(request)
    }

    func cancelComputerUse(sessionID: String, serviceToken: String) async throws {
        guard !serviceToken.isEmpty else { throw BackendError.missingServiceToken }
        var request = makeRequest(path: "computer-use/sessions/\(sessionID)", serviceToken: serviceToken)
        request.httpMethod = "DELETE"
        let _: BackendCancelResponse = try await send(request)
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
        multipartBody(parts: [(name: fieldName, filename: filename, contentType: contentType, data: data)], boundary: boundary)
    }

    private static func multipartBody(
        parts: [(name: String, filename: String?, contentType: String, data: Data)],
        boundary: String
    ) -> Data {
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            if let filename = part.filename {
                body.append(Data("Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(filename)\"\r\n".utf8))
            } else {
                body.append(Data("Content-Disposition: form-data; name=\"\(part.name)\"\r\n".utf8))
            }
            body.append(Data("Content-Type: \(part.contentType)\r\n\r\n".utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    private static func compatibilityOrigins(initialURL: URL, currentURL: String) -> [String] {
        var origins: [String] = []
        for value in [initialURL.absoluteString, currentURL] {
            guard let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host else { continue }
            let origin = "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
            if !origins.contains(origin) { origins.append(origin) }
        }
        return origins
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

nonisolated struct BackendCancelResponse: Decodable, Sendable {
    let status: String
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case status
        case sessionID = "session_id"
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
