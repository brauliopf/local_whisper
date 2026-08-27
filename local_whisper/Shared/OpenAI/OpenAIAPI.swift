import Foundation

nonisolated enum OpenAIAPI: Sendable {
    static let chatCompletions = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let transcriptions = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    struct ChatCompletionRequest: Encodable, Sendable {
        var model: String
        var messages: [ChatMessage]
        var temperature: Double?
        var maxTokens: Int?

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case maxTokens = "max_tokens"
        }
    }

    struct ChatMessage: Encodable, Sendable {
        var role: String
        var content: Content

        enum Content: Sendable {
            case text(String)
            case parts([ContentPart])
        }

        enum CodingKeys: String, CodingKey {
            case role, content
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            switch content {
            case .text(let text):
                try container.encode(text, forKey: .content)
            case .parts(let parts):
                try container.encode(parts, forKey: .content)
            }
        }
    }

    struct ContentPart: Encodable, Sendable {
        var type: String
        var text: String?
        var imageURL: ImageURL?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }

        struct ImageURL: Encodable, Sendable {
            var url: String
        }
    }

    struct ChatCompletionResponse: Decodable, Sendable {
        var choices: [Choice]

        struct Choice: Decodable {
            var message: Message
            struct Message: Decodable {
                var content: String?
            }
        }

        var firstText: String? {
            choices.first?.message.content?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    struct TranscriptionResponse: Decodable, Sendable {
        var text: String
    }

    struct ErrorResponse: Decodable, Sendable {
        var error: Payload
        struct Payload: Decodable {
            var message: String
        }
    }
}
