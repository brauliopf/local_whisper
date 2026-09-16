import Foundation

nonisolated enum OpenAIJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: OpenAIJSONValue])
    case array([OpenAIJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String: OpenAIJSONValue].self) { self = .object(value); return }
        self = .array(try container.decode([OpenAIJSONValue].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

nonisolated enum OpenAIResponsesAPI: Sendable {
    struct Request: Encodable, Sendable {
        var model: String
        var input: [OpenAIJSONValue]
        var tools: [Tool] = []
        var previousResponseID: String?
        var instructions: String?
        var text: TextConfiguration?
        var parallelToolCalls: Bool?

        enum CodingKeys: String, CodingKey {
            case model, input, tools, instructions, text
            case previousResponseID = "previous_response_id"
            case parallelToolCalls = "parallel_tool_calls"
        }
    }

    struct Tool: Encodable, Sendable {
        var type = "function"
        var name: String
        var description: String
        var parameters: OpenAIJSONValue
        var strict = true
    }

    struct TextConfiguration: Encodable, Sendable {
        var format: Format

        struct Format: Encodable, Sendable {
            var type = "json_schema"
            var name: String
            var schema: OpenAIJSONValue
            var strict = true
        }
    }

    struct Response: Decodable, Sendable {
        var id: String
        var output: [OutputItem]

        var functionCall: OutputItem? {
            output.first { $0.type == "function_call" }
        }

        var messageText: String? {
            output.first(where: { $0.type == "message" })?.content?.compactMap(\.text).joined()
        }
    }

    struct OutputItem: Decodable, Sendable {
        var type: String
        var name: String?
        var arguments: String?
        var callID: String?
        var content: [ContentItem]?

        enum CodingKeys: String, CodingKey {
            case type, name, arguments, content
            case callID = "call_id"
        }
    }

    struct ContentItem: Decodable, Sendable {
        var type: String?
        var text: String?
    }
}
