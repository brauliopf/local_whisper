import Observation
import SwiftUI

@MainActor
@Observable
final class FlightSearchWorkflow {
    enum State: Equatable {
        case idle
        case running
        case completed(String)
        case failed(String)
    }

    var task = "Find the best nonstop flights for my trip."
    private(set) var state: State = .idle

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    private let runSearch: (String) async throws -> String
    private var searchTask: Task<Void, Never>?

    init(
        task: String = "Find the best nonstop flights for my trip.",
        runSearch: @escaping (String) async throws -> String
    ) {
        self.task = task
        self.runSearch = runSearch
    }

    static func live(keychain: any Keychaining = KeychainStore()) -> FlightSearchWorkflow {
        let environment = ProcessInfo.processInfo.environment
        let model = environment["OPENAI_RESPONSES_MODEL"] ?? ModelSettings.chat
        let nodePath = environment["LOCAL_WHISPER_NODE"]
        let executorPath = environment["LOCAL_WHISPER_EXECUTOR"]

        return FlightSearchWorkflow { task in
            guard let apiKey = keychain.loadAPIKey(), !apiKey.isEmpty else {
                throw OpenAIError.missingAPIKey
            }
            guard let nodePath, !nodePath.isEmpty else {
                throw ComputerUseCoordinatorError.invalidConfiguration(
                    "Set LOCAL_WHISPER_NODE before starting a flight search."
                )
            }
            guard let executorPath, !executorPath.isEmpty else {
                throw ComputerUseCoordinatorError.invalidConfiguration(
                    "Set LOCAL_WHISPER_EXECUTOR before starting a flight search."
                )
            }

            let browser = NodeBrowserExecutor(
                nodeURL: URL(fileURLWithPath: nodePath),
                executorURL: URL(fileURLWithPath: executorPath)
            )
            let coordinator = ComputerUseCoordinator(
                responses: OpenAIResponsesClient(),
                browser: browser
            )
            let artifactDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("local-whisper-flight-\(UUID().uuidString)")
            let configuration = BrowserConfiguration(
                initialURL: URL(string: "https://www.google.com/travel/flights")!,
                allowedOrigins: ["https://www.google.com"],
                artifactDirectory: artifactDirectory
            )
            defer { try? FileManager.default.removeItem(at: artifactDirectory) }

            return try await coordinator.run(
                task: task,
                model: model,
                apiKey: apiKey,
                browserConfiguration: configuration
            )
        }
    }

    func start() {
        guard !isRunning else { return }
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            state = .failed("Describe the flight research you want to run.")
            return
        }

        state = .running
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runSearch(task)
                guard !Task.isCancelled else { return }
                state = .completed(result)
            } catch is CancellationError {
                return
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        state = .idle
    }
}

struct FlightSearchView: View {
    @Bindable private var workflow: FlightSearchWorkflow

    init(workflow: FlightSearchWorkflow) {
        self.workflow = workflow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Flight research")
                .font(.title2.weight(.semibold))

            Text("Run read-only research with Google Flights. Describe the trip or question you want to investigate.")
                .foregroundStyle(.secondary)

            TextEditor(text: $workflow.task)
                .font(.body)
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .disabled(workflow.isRunning)

            HStack {
                if workflow.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Researching…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: workflow.cancel)
                } else {
                    Spacer()
                    Button("Start research", action: workflow.start)
                        .keyboardShortcut(.return, modifiers: [.command])
                }
            }

            switch workflow.state {
            case .idle:
                EmptyView()
            case .running:
                EmptyView()
            case .completed(let result):
                ScrollView {
                    Text(result)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 500, height: 390)
    }
}
