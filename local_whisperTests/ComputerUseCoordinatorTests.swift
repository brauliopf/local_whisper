import Foundation
import XCTest
@testable import local_whisper

final class ComputerUseCoordinatorTests: XCTestCase {
    func testRunsBrowserRoundThenReturnsFinalMessage() async throws {
        let responses = FakeResponsesClient(responses: [
            .success(functionCall(id: "resp_1", callID: "call_1", module: "module-one")),
            .success(message(id: "resp_2", text: "I found one result.")),
        ])
        let browser = FakeBrowserExecutor(results: [browserResult(text: ["one"])])
        let coordinator = makeCoordinator(responses: responses, browser: browser)

        let result = try await coordinator.run(
            task: "Find one result",
            model: "gpt-test",
            apiKey: "test-key",
            browserConfiguration: configuration
        )

        XCTAssertEqual(result, "I found one result.")
        let modules = await browser.modules()
        let stopCount = await browser.stopCount()
        XCTAssertEqual(modules, ["module-one"])
        XCTAssertEqual(stopCount, 1)
        let requests = await responses.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].tools.first?.name, "execute_playwright")
        XCTAssertEqual(requests[0].tools.first?.description, "Execute one Playwright JavaScript module against the current browser page. The module may inspect and interact with the page.")
        XCTAssertTrue(requests[0].instructions?.contains("module.exports") == true)
        XCTAssertTrue(requests[0].instructions?.contains("{ page, context, screenshot }") == true)
        XCTAssertTrue(requests[0].instructions?.contains("generic table") == true)
        XCTAssertEqual(requests[0].parallelToolCalls, false)
        XCTAssertEqual(requests[1].previousResponseID, "resp_1")
        XCTAssertEqual(requests[1].parallelToolCalls, false)
        XCTAssertEqual(requests[1].input.first?["call_id"], .string("call_1"))
        guard case .string(let output) = requests[1].input.first?["output"] else {
            return XCTFail("Expected browser result output")
        }
        let encodedResult = try JSONDecoder().decode(BrowserExecutorResult.self, from: Data(output.utf8))
        XCTAssertEqual(encodedResult.text, ["one"])
    }

    func testIncludesRequestedScreenshotArtifactsInNextModelInput() async throws {
        let screenshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("computer-use-test-\(UUID().uuidString).png")
        try Data([0, 1, 2]).write(to: screenshotURL)
        defer { try? FileManager.default.removeItem(at: screenshotURL) }

        let responses = FakeResponsesClient(responses: [
            .success(functionCall(id: "resp_1", callID: "call_1", module: "module-one")),
            .success(message(id: "resp_2", text: "Finished.")),
        ])
        let browser = FakeBrowserExecutor(results: [
            .init(
                ok: true,
                value: nil,
                text: [],
                artifacts: [.init(path: screenshotURL.path, mimeType: "image/png", label: "page")],
                browser: .init(url: "https://example.test", title: "Example"),
                error: nil
            ),
        ])
        let coordinator = makeCoordinator(responses: responses, browser: browser)

        _ = try await coordinator.run(
            task: "Inspect the page",
            model: "gpt-test",
            apiKey: "test-key",
            browserConfiguration: configuration
        )

        let requests = await responses.requests()
        XCTAssertEqual(requests[1].input.count, 2)
        guard case .array(let content) = requests[1].input[1]["content"],
              let image = content.first,
              case .string(let imageURL) = image["image_url"] else {
            return XCTFail("Expected a data URL image input")
        }
        XCTAssertEqual(requests[1].input[1]["role"], .string("user"))
        XCTAssertTrue(imageURL.hasPrefix("data:image/png;base64,"))
    }

    func testRunsMultipleSequentialBrowserRounds() async throws {
        let responses = FakeResponsesClient(responses: [
            .success(functionCall(id: "resp_1", callID: "call_1", module: "module-one")),
            .success(functionCall(id: "resp_2", callID: "call_2", module: "module-two")),
            .success(message(id: "resp_3", text: "Finished.")),
        ])
        let browser = FakeBrowserExecutor(results: [
            browserResult(text: ["one"]),
            browserResult(text: ["two"]),
        ])
        let coordinator = makeCoordinator(responses: responses, browser: browser)

        let result = try await coordinator.run(
            task: "Find two results",
            model: "gpt-test",
            apiKey: "test-key",
            browserConfiguration: configuration
        )

        XCTAssertEqual(result, "Finished.")
        let modules = await browser.modules()
        let stopCount = await browser.stopCount()
        XCTAssertEqual(modules, ["module-one", "module-two"])
        XCTAssertEqual(stopCount, 1)
    }

    func testRejectsMalformedFunctionArguments() async throws {
        let responses = FakeResponsesClient(responses: [
            .success(.init(id: "resp_1", output: [
                .init(type: "function_call", name: "execute_playwright", arguments: "not-json", callID: "call_1", content: nil),
            ])),
        ])
        let browser = FakeBrowserExecutor(results: [browserResult(text: ["unused"])])
        let coordinator = makeCoordinator(responses: responses, browser: browser)

        do {
            _ = try await coordinator.run(
                task: "Run a module",
                model: "gpt-test",
                apiKey: "test-key",
                browserConfiguration: configuration
            )
            XCTFail("Expected malformed arguments error")
        } catch let error as ComputerUseCoordinatorError {
            XCTAssertEqual(error, .invalidFunctionCall("Arguments were not valid JSON."))
        }
        let modules = await browser.modules()
        let stopCount = await browser.stopCount()
        XCTAssertEqual(modules, [])
        XCTAssertEqual(stopCount, 1)
    }

    func testRejectsMissingModuleArgument() async throws {
        let responses = FakeResponsesClient(responses: [
            .success(.init(id: "resp_1", output: [
                .init(type: "function_call", name: "execute_playwright", arguments: "{}", callID: "call_1", content: nil),
            ])),
        ])
        let browser = FakeBrowserExecutor(results: [browserResult(text: ["unused"])])
        let coordinator = makeCoordinator(responses: responses, browser: browser)

        do {
            _ = try await coordinator.run(
                task: "Run a module",
                model: "gpt-test",
                apiKey: "test-key",
                browserConfiguration: configuration
            )
            XCTFail("Expected missing module error")
        } catch let error as ComputerUseCoordinatorError {
            XCTAssertEqual(error, .invalidFunctionCall("The module argument is required."))
        }
        let stopCount = await browser.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testRejectsUnusableModelOutput() async throws {
        let responses = FakeResponsesClient(responses: [.success(.init(id: "resp_1", output: []))])
        let browser = FakeBrowserExecutor(results: [])
        let coordinator = makeCoordinator(responses: responses, browser: browser)

        do {
            _ = try await coordinator.run(
                task: "Do something",
                model: "gpt-test",
                apiKey: "test-key",
                browserConfiguration: configuration
            )
            XCTFail("Expected unusable response error")
        } catch let error as ComputerUseCoordinatorError {
            XCTAssertEqual(error, .unusableModelResponse)
        }
        let stopCount = await browser.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testEnforcesMaximumBrowserRounds() async throws {
        let responses = FakeResponsesClient(responses: [
            .success(functionCall(id: "resp_1", callID: "call_1", module: "module-one")),
            .success(functionCall(id: "resp_2", callID: "call_2", module: "module-two")),
        ])
        let browser = FakeBrowserExecutor(results: [browserResult(text: ["one"])])
        let coordinator = ComputerUseCoordinator(responses: responses, browser: browser, maxRounds: 1)

        do {
            _ = try await coordinator.run(
                task: "Find results",
                model: "gpt-test",
                apiKey: "test-key",
                browserConfiguration: configuration
            )
            XCTFail("Expected maximum rounds error")
        } catch let error as ComputerUseCoordinatorError {
            XCTAssertEqual(error, .maxRoundsExceeded(1))
        }
        let modules = await browser.modules()
        let stopCount = await browser.stopCount()
        XCTAssertEqual(modules, ["module-one"])
        XCTAssertEqual(stopCount, 1)
    }

    func testStopsAfterBrowserFailure() async throws {
        let responses = FakeResponsesClient(responses: [
            .success(functionCall(id: "resp_1", callID: "call_1", module: "module-one")),
        ])
        let browser = FakeBrowserExecutor(results: [], executeFails: true)
        let coordinator = makeCoordinator(responses: responses, browser: browser)

        do {
            _ = try await coordinator.run(
                task: "Run a module",
                model: "gpt-test",
                apiKey: "test-key",
                browserConfiguration: configuration
            )
            XCTFail("Expected browser failure")
        } catch is StubError {
            // Expected.
        }
        let stopCount = await browser.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testStopsAfterResponsesFailure() async throws {
        let responses = FakeResponsesClient(responses: [.failure(.responsesFailure)])
        let browser = FakeBrowserExecutor(results: [])
        let coordinator = makeCoordinator(responses: responses, browser: browser)

        do {
            _ = try await coordinator.run(
                task: "Do something",
                model: "gpt-test",
                apiKey: "test-key",
                browserConfiguration: configuration
            )
            XCTFail("Expected Responses failure")
        } catch is StubError {
            // Expected.
        }
        let stopCount = await browser.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testDoesNotStopWhenBrowserStartFails() async throws {
        let responses = FakeResponsesClient(responses: [])
        let browser = FakeBrowserExecutor(results: [], startFails: true)
        let coordinator = makeCoordinator(responses: responses, browser: browser)

        do {
            _ = try await coordinator.run(
                task: "Do something",
                model: "gpt-test",
                apiKey: "test-key",
                browserConfiguration: configuration
            )
            XCTFail("Expected browser start failure")
        } catch is StubError {
            // Expected.
        }
        let stopCount = await browser.stopCount()
        XCTAssertEqual(stopCount, 0)
    }

    func testCancellationStopsBrowserAfterStart() async throws {
        let responses = BlockingResponsesClient()
        let browser = FakeBrowserExecutor(results: [])
        let coordinator = makeCoordinator(responses: responses, browser: browser)
        let run = Task<String, Error> {
            try await coordinator.run(
                task: "Wait for cancellation",
                model: "gpt-test",
                apiKey: "test-key",
                browserConfiguration: configuration
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        run.cancel()

        do {
            _ = try await run.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let stopCount = await browser.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    private let configuration = BrowserConfiguration(
        initialURL: URL(string: "https://example.test")!,
        allowedOrigins: ["https://example.test"],
        artifactDirectory: URL(fileURLWithPath: "/tmp/computer-use-tests")
    )

    private func makeCoordinator(
        responses: any OpenAIResponsesClienting,
        browser: any BrowserExecuting
    ) -> ComputerUseCoordinator {
        ComputerUseCoordinator(responses: responses, browser: browser)
    }

    private func functionCall(
        id: String,
        callID: String,
        module: String
    ) -> OpenAIResponsesAPI.Response {
        let arguments = "{\"module\":\"\(module)\"}"
        return .init(id: id, output: [
            .init(type: "function_call", name: "execute_playwright", arguments: arguments, callID: callID, content: nil),
        ])
    }

    private func message(id: String, text: String) -> OpenAIResponsesAPI.Response {
        .init(id: id, output: [
            .init(type: "message", name: nil, arguments: nil, callID: nil, content: [
                .init(type: "output_text", text: text),
            ]),
        ])
    }

    private func browserResult(text: [String]) -> BrowserExecutorResult {
        .init(
            ok: true,
            value: nil,
            text: text,
            artifacts: nil,
            browser: .init(url: "https://example.test", title: "Example"),
            error: nil
        )
    }
}

private enum StubError: Error, Sendable {
    case browserFailure
    case responsesFailure
    case startFailure
}

private actor FakeResponsesClient: OpenAIResponsesClienting {
    private var queuedResponses: [Result<OpenAIResponsesAPI.Response, StubError>]
    private var capturedRequests: [OpenAIResponsesAPI.Request] = []

    init(responses: [Result<OpenAIResponsesAPI.Response, StubError>]) {
        self.queuedResponses = responses
    }

    func createResponse(
        _ request: OpenAIResponsesAPI.Request,
        apiKey: String,
        timeout: TimeInterval
    ) async throws -> OpenAIResponsesAPI.Response {
        capturedRequests.append(request)
        guard !queuedResponses.isEmpty else { throw StubError.responsesFailure }
        return try queuedResponses.removeFirst().get()
    }

    func requests() -> [OpenAIResponsesAPI.Request] {
        capturedRequests
    }
}

private actor BlockingResponsesClient: OpenAIResponsesClienting {
    func createResponse(
        _ request: OpenAIResponsesAPI.Request,
        apiKey: String,
        timeout: TimeInterval
    ) async throws -> OpenAIResponsesAPI.Response {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        throw CancellationError()
    }
}

private actor FakeBrowserExecutor: BrowserExecuting {
    private var queuedResults: [BrowserExecutorResult]
    private var recordedModules: [String] = []
    private var starts = 0
    private var stops = 0
    private let startFails: Bool
    private let executeFails: Bool

    init(
        results: [BrowserExecutorResult],
        startFails: Bool = false,
        executeFails: Bool = false
    ) {
        self.queuedResults = results
        self.startFails = startFails
        self.executeFails = executeFails
    }

    func start(configuration: BrowserConfiguration) async throws -> BrowserSessionInfo {
        starts += 1
        if startFails { throw StubError.startFailure }
        return .init(url: configuration.initialURL.absoluteString, title: "Example")
    }

    func execute(module: String) async throws -> BrowserExecutorResult {
        recordedModules.append(module)
        if executeFails { throw StubError.browserFailure }
        guard !queuedResults.isEmpty else { throw StubError.browserFailure }
        return queuedResults.removeFirst()
    }

    func stop() async {
        stops += 1
    }

    func modules() -> [String] { recordedModules }
    func stopCount() -> Int { stops }
}

private extension OpenAIJSONValue {
    subscript(key: String) -> OpenAIJSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }
}
