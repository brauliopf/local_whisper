import AppKit
import Foundation

enum OpenAIError: LocalizedError {
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

struct OpenAIService {
    private static let systemPrompt = """
        You give brief, warm words of general encouragement.
        Reply with exactly one short sentence, no more than 15 words.
        No quotes, labels, or preamble — just the encouragement.
        """

    func fetchEncouragement() async throws -> String {
        guard let apiKey = KeychainService.loadAPIKey(), !apiKey.isEmpty else {
            throw OpenAIError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": "Give me a word of encouragement."],
            ],
            "max_tokens": 60,
            "temperature": 0.9,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OpenAIError.network(Self.networkMessage(for: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        if http.statusCode != 200 {
            let message = Self.parseErrorMessage(from: data) ?? "Couldn't fetch a message — check your API key."
            throw OpenAIError.apiError(message)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw OpenAIError.invalidResponse
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenAIError.invalidResponse }
        return trimmed
    }

    func transcribeAudio(at fileURL: URL) async throws -> String {
        guard let apiKey = KeychainService.loadAPIKey(), !apiKey.isEmpty else {
            throw OpenAIError.missingAPIKey
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90

        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        var body = Data()
        Self.appendFormField("model", value: "gpt-4o-mini-transcribe", boundary: boundary, to: &body)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: audio/mp4\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OpenAIError.network(Self.networkMessage(for: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.apiError("Couldn't transcribe — try again.")
        }

        if http.statusCode != 200 {
            let message = Self.parseErrorMessage(from: data) ?? "Couldn't transcribe — check your API key."
            throw OpenAIError.apiError(message)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else {
            throw OpenAIError.apiError("Couldn't transcribe — try again.")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OpenAIError.apiError("Nothing to transcribe") }
        return trimmed
    }

    func extractText(fromImageAt fileURL: URL) async throws -> String? {
        guard let apiKey = KeychainService.loadAPIKey(), !apiKey.isEmpty else {
            throw OpenAIError.missingAPIKey
        }

        let jpegData = try Self.jpegData(from: fileURL)
        let base64 = jpegData.base64EncodedString()
        let prompt = """
            Extract all readable text from this image verbatim.
            Do not add a preamble, labels, quotes, or commentary.
            Preserve line breaks.
            If there is no readable text, reply with exactly NO_TEXT.
            """

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "temperature": 0,
            "max_tokens": 4096,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        [
                            "type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64,\(base64)"],
                        ],
                    ],
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OpenAIError.network(Self.networkMessage(for: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.apiError("Couldn't read the image — try again.")
        }

        if http.statusCode != 200 {
            let message = Self.parseErrorMessage(from: data) ?? "Couldn't read the image — check your API key."
            throw OpenAIError.apiError(message)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw OpenAIError.apiError("Couldn't read the image — try again.")
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.uppercased() == "NO_TEXT" {
            return nil
        }
        return trimmed
    }

    private static func jpegData(from fileURL: URL) throws -> Data {
        guard
            let image = NSImage(contentsOf: fileURL),
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else {
            throw OpenAIError.apiError("Couldn't read the screenshot.")
        }
        return data
    }

    private static func appendFormField(_ name: String, value: String, boundary: String, to body: inout Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
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

    private static func parseErrorMessage(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String
        else { return nil }
        return "Couldn't fetch a message — \(message)"
    }
}
