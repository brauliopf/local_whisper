import Foundation

nonisolated enum ComputerUseCoordinatorError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case invalidFunctionCall(String)
    case unusableModelResponse
    case maxRoundsExceeded(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid computer-use configuration: \(message)"
        case .invalidFunctionCall(let message):
            return "Invalid browser function call: \(message)"
        case .unusableModelResponse:
            return "The model returned neither a browser function call nor message text."
        case .maxRoundsExceeded(let maxRounds):
            return "The computer-use task exceeded the maximum of \(maxRounds) browser rounds."
        }
    }
}

struct ComputerUseCoordinator: Sendable {
    private static let toolName = "execute_playwright"
    private static let defaultResponseTimeout: TimeInterval = 120
    private static let modelInstructions = """
        You are controlling a browser through the execute_playwright tool.
        When acting, provide a JavaScript module whose source assigns an async function to module.exports.
        The function receives exactly { page, context, screenshot }.
        Use Playwright APIs through page or context for all browser inspection and interaction; do not use document, window, or other direct DOM APIs.
        The function must return observations as a generic table object with this shape:
        { type: \"table\", columns: string[], rows: string[][], notes: string[] }.
        Return useful observations from the current browser state, not a final answer. After the observations are returned, you may provide the final answer in your assistant message.
        """

    private let responses: any OpenAIResponsesClienting
    private let browser: any BrowserExecuting
    private let maxRounds: Int
    private let responseTimeout: TimeInterval

    init(
        responses: any OpenAIResponsesClienting,
        browser: any BrowserExecuting,
        maxRounds: Int = 8,
        responseTimeout: TimeInterval = defaultResponseTimeout
    ) {
        self.responses = responses
        self.browser = browser
        self.maxRounds = maxRounds
        self.responseTimeout = responseTimeout
    }

    func run(
        task: String,
        model: String,
        apiKey: String,
        browserConfiguration: BrowserConfiguration
    ) async throws -> String {
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComputerUseCoordinatorError.invalidConfiguration("The task cannot be empty.")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComputerUseCoordinatorError.invalidConfiguration("The model cannot be empty.")
        }
        guard maxRounds > 0 else {
            throw ComputerUseCoordinatorError.invalidConfiguration("Maximum rounds must be greater than zero.")
        }

        _ = try await browser.start(configuration: browserConfiguration)

        do {
            let result = try await runLoop(
                task: task,
                model: model,
                apiKey: apiKey
            )
            await browser.stop()
            return result
        } catch {
            await browser.stop()
            throw error
        }
    }

    private func runLoop(
        task: String,
        model: String,
        apiKey: String
    ) async throws -> String {
        let tool = Self.playwrightTool
        var request = OpenAIResponsesAPI.Request(
            model: model,
            input: [
                .object([
                    "role": .string("user"),
                    "content": .string(task),
                ]),
            ],
            tools: [tool],
            instructions: Self.modelInstructions,
            parallelToolCalls: false
        )
        var browserRounds = 0
        let encoder = JSONEncoder()

        while true {
            let response = try await responses.createResponse(
                request,
                apiKey: apiKey,
                timeout: responseTimeout
            )

            if let functionCall = response.functionCall {
                guard browserRounds < maxRounds else {
                    throw ComputerUseCoordinatorError.maxRoundsExceeded(maxRounds)
                }
                let module = try Self.module(from: functionCall)
                guard let callID = functionCall.callID, !callID.isEmpty else {
                    throw ComputerUseCoordinatorError.invalidFunctionCall("The function call is missing call_id.")
                }
                let browserResult = try await browser.execute(module: module)
                let output = try encoder.encode(browserResult)
                guard let outputString = String(data: output, encoding: .utf8) else {
                    throw ComputerUseCoordinatorError.invalidFunctionCall("Could not encode browser output.")
                }

                browserRounds += 1
                let observationInput: [OpenAIJSONValue] = [
                    .object([
                        "type": .string("function_call_output"),
                        "call_id": .string(callID),
                        "output": .string(outputString),
                    ]),
                ] + Self.screenshotInputs(from: browserResult)
                request = OpenAIResponsesAPI.Request(
                    model: model,
                    input: observationInput,
                    tools: [tool],
                    previousResponseID: response.id,
                    instructions: Self.modelInstructions,
                    parallelToolCalls: false
                )
                continue
            }

            if let messageText = response.messageText,
               !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return messageText
            }

            throw ComputerUseCoordinatorError.unusableModelResponse
        }
    }

    private static func module(from functionCall: OpenAIResponsesAPI.OutputItem) throws -> String {
        guard functionCall.name == toolName else {
            throw ComputerUseCoordinatorError.invalidFunctionCall(
                "Expected \(toolName), received \(functionCall.name ?? "no name")."
            )
        }
        guard let arguments = functionCall.arguments,
              let data = arguments.data(using: .utf8) else {
            throw ComputerUseCoordinatorError.invalidFunctionCall("The function call is missing arguments.")
        }

        struct Arguments: Decodable {
            var module: String?
        }

        let decoded: Arguments
        do {
            decoded = try JSONDecoder().decode(Arguments.self, from: data)
        } catch {
            throw ComputerUseCoordinatorError.invalidFunctionCall("Arguments were not valid JSON.")
        }
        guard let module = decoded.module?.trimmingCharacters(in: .whitespacesAndNewlines), !module.isEmpty else {
            throw ComputerUseCoordinatorError.invalidFunctionCall("The module argument is required.")
        }
        return module
    }

    private static func screenshotInputs(from result: BrowserExecutorResult) -> [OpenAIJSONValue] {
        let images = result.artifacts?.compactMap { artifact -> OpenAIJSONValue? in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: artifact.path)) else { return nil }
            let imageURL = "data:\(artifact.mimeType);base64,\(data.base64EncodedString())"
            return .object([
                "type": .string("input_image"),
                "image_url": .string(imageURL),
                "detail": .string("auto"),
            ])
        } ?? []
        guard !images.isEmpty else { return [] }
        return [.object([
            "role": .string("user"),
            "content": .array(images),
        ])]
    }

    private static var playwrightTool: OpenAIResponsesAPI.Tool {
        .init(
            name: toolName,
            description: "Execute one Playwright JavaScript module against the current browser page. The module may inspect and interact with the page.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "module": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("module")]),
                "additionalProperties": .bool(false),
            ])
        )
    }
}
