import Foundation
import XCTest
@testable import local_whisper

final class OpenAIResponsesTests: XCTestCase {
    func testRequestEncodesConversationAndFunctionTool() throws {
        let request = OpenAIResponsesAPI.Request(
            model: "gpt-test",
            input: [.object(["role": .string("user"), "content": .string("Search flights")])],
            tools: [
                .init(
                    name: "execute_playwright",
                    description: "Run a read-only browser module.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object(["module": .object(["type": .string("string")])]),
                        "required": .array([.string("module")]),
                        "additionalProperties": .bool(false),
                    ])
                ),
            ],
            previousResponseID: "resp_previous"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "gpt-test")
        XCTAssertEqual(object["previous_response_id"] as? String, "resp_previous")
        XCTAssertEqual((object["tools"] as? [[String: Any]])?.count, 1)
    }

    func testResponseFindsFunctionCallAndMessageText() throws {
        let data = Data(#"{"id":"resp_123","output":[{"type":"function_call","name":"execute_playwright","call_id":"call_123","arguments":"{\"module\":\"module.exports = async () => ({})\"}"},{"type":"message","content":[{"type":"output_text","text":"Finished"}]}]}"#.utf8)
        let response = try JSONDecoder().decode(OpenAIResponsesAPI.Response.self, from: data)

        XCTAssertEqual(response.id, "resp_123")
        XCTAssertEqual(response.functionCall?.name, "execute_playwright")
        XCTAssertEqual(response.functionCall?.callID, "call_123")
        XCTAssertEqual(response.messageText, "Finished")
    }

    func testClientUsesTransportAndAcceptsSuccessfulResponses() async throws {
        StubResponsesURLProtocol.responseData = Data(#"{"id":"resp_456","output":[{"type":"message","content":[{"type":"output_text","text":"Done"}]}]}"#.utf8)
        StubResponsesURLProtocol.statusCode = 201
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubResponsesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenAIResponsesClient(
            transport: OpenAITransport(session: session),
            endpoint: URL(string: "https://example.test/v1/responses")!
        )

        let response = try await client.createResponse(
            .init(model: "gpt-test", input: [.string("hello")]),
            apiKey: "test-key",
            timeout: 5
        )

        XCTAssertEqual(response.id, "resp_456")
        XCTAssertEqual(StubResponsesURLProtocol.lastAuthorization, "Bearer test-key")
    }
}

private final class StubResponsesURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var lastAuthorization: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
