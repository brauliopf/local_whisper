import XCTest
@testable import local_whisper

final class BackendClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.state.reset()
        super.tearDown()
    }

    func testChatCompletionRequestOmitsConversationIDWhenNil() throws {
        let data = try JSONEncoder().encode(
            ChatCompletionRequest(text: "Hello", conversationID: nil)
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(body["text"] as? String, "Hello")
        XCTAssertNil(body["conversation_id"])
    }

    func testChatCompletionRequestEncodesConversationID() throws {
        let data = try JSONEncoder().encode(
            ChatCompletionRequest(text: "Hello", conversationID: "conversation-123")
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(body["text"] as? String, "Hello")
        XCTAssertEqual(body["conversation_id"] as? String, "conversation-123")
    }

    func testCompleteReturnsResponseTextAndConversationID() async throws {
        StubURLProtocol.state.configure(
            data: Data(
                #"{"text":" Answer ","request_id":"request-123","conversation_id":"conversation-123"}"#.utf8
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = BackendClient(
            session: session,
            baseURL: URL(string: "https://backend.test")!
        )

        let result = try await client.complete(
            text: "Hello",
            conversationID: "conversation-123",
            serviceToken: "test-token"
        )

        XCTAssertEqual(result.text, "Answer")
        XCTAssertEqual(result.conversationID, "conversation-123")
        let request = try XCTUnwrap(StubURLProtocol.state.capturedRequest)
        XCTAssertEqual(request.url?.path, "/chat-completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }
}

private final class StubResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var responseData = Data()
    private var request: URLRequest?

    func configure(data: Data) {
        lock.lock()
        defer { lock.unlock() }
        responseData = data
        request = nil
    }

    func result(for request: URLRequest) -> (HTTPURLResponse, Data) {
        lock.lock()
        defer { lock.unlock() }
        self.request = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, responseData)
    }

    var capturedRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        responseData = Data()
        request = nil
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = StubResponseState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (response, data) = Self.state.result(for: request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
