import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ComputerUseCoordinator {
    struct TimelineItem: Identifiable, Sendable {
        let id = UUID()
        var title: String
        var detail: String
        var risk: String?
    }

    struct PendingApproval: Sendable {
        var sessionID: String
        var stepID: String
        var codeHash: String
        var browserStateHash: String
        var summary: String
        var code: String
    }

    var isVisible = false
    var isRunning = false
    var timeline: [TimelineItem] = []
    var pendingApproval: PendingApproval?
    var errorMessage: String?

    private let backend: any BackendClienting
    private let keychain: any Keychaining
    private let toast: ToastPresenter
    private let panel: ComputerUsePanelController
    private var executor: (any BrowserExecuting)?
    private var lastBrowserState: BrowserState?
    private var sessionID: String?
    private var task: Task<Void, Never>?

    init(
        backend: any BackendClienting,
        keychain: any Keychaining,
        toast: ToastPresenter
    ) {
        self.backend = backend
        self.keychain = keychain
        self.toast = toast
        self.panel = ComputerUsePanelController()
        self.panel.onApprove = { [weak self] in self?.approve() }
        self.panel.onDeny = { [weak self] in self?.deny() }
        self.panel.onCancel = { [weak self] in self?.cancel() }
        self.panel.onClearProfile = { [weak self] in self?.clearBrowserProfile() }
        self.panel.setContent(self)
    }

    func beginRecording() {
        guard !isRunning else {
            toast.show(message: "A computer-use task is already running.", isError: true)
            return
        }
        isVisible = true
        panel.show()
        timeline = [TimelineItem(title: "Listening", detail: "Speak an instruction, then press ⌃⌥A to stop.", risk: nil)]
        errorMessage = nil
    }

    func receiveInstruction(_ result: Result<String, Error>) {
        switch result {
        case .failure(let error):
            fail(error.localizedDescription)
        case .success(let instruction):
            timeline.append(TimelineItem(title: "Transcribing", detail: "Instruction received.", risk: nil))
            guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fail("No instruction detected.")
                return
            }
            start(instruction: instruction)
        }
    }

    func approve() {
        guard let pendingApproval, let token = keychain.loadServiceToken(), !token.isEmpty else { return }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await backend.approveComputerUseStep(
                    sessionID: pendingApproval.sessionID,
                    stepID: pendingApproval.stepID,
                    codeHash: pendingApproval.codeHash,
                    browserStateHash: pendingApproval.browserStateHash,
                    serviceToken: token
                )
                self.pendingApproval = nil
                self.append(response.step, prefix: "Approved")
                try await self.execute(response)
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    func deny() {
        guard let pendingApproval, let token = keychain.loadServiceToken(), !token.isEmpty else { return }
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await backend.denyComputerUseStep(
                    sessionID: pendingApproval.sessionID,
                    stepID: pendingApproval.stepID,
                    serviceToken: token
                )
                self.pendingApproval = nil
                self.finish(message: "Task denied.")
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    func clearBrowserProfile() {
        guard !isRunning else {
            toast.show(message: "Finish or cancel the current task before clearing browser sign-in.", isError: true)
            return
        }
        guard let executor else {
            if let configuration = try? ComputerUseLocalConfiguration.load() {
                try? FileManager.default.removeItem(at: configuration.browser.profileDirectory)
            }
            timeline.append(TimelineItem(title: "Browser sign-in cleared", detail: "The next login will be interactive.", risk: nil))
            panel.show()
            return
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await executor.clearProfile()
                self.executor = nil
                self.lastBrowserState = nil
                self.task = nil
                self.timeline.append(TimelineItem(title: "Browser sign-in cleared", detail: "The next login will be interactive.", risk: nil))
                self.panel.show()
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        let sessionID = self.sessionID
        let token = keychain.loadServiceToken()
        if let sessionID, let token, !token.isEmpty {
            Task { try? await backend.cancelComputerUse(sessionID: sessionID, serviceToken: token) }
        }
        finish(message: "Task cancelled.")
    }

    private func start(instruction: String) {
        guard let token = keychain.loadServiceToken(), !token.isEmpty else {
            toast.show(message: "Add the backend service token in Settings.", isError: true)
            return
        }
        task?.cancel()
        isRunning = true
        timeline.append(TimelineItem(title: "Instruction", detail: instruction, risk: nil))
        timeline.append(TimelineItem(title: "Planning", detail: "Preparing the next browser action.", risk: nil))
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let configuration = try ComputerUseLocalConfiguration.load()
                let browser: any BrowserExecuting
                let browserState: BrowserSessionInfo
                if let existing = self.executor, let lastBrowserState = self.lastBrowserState {
                    browser = existing
                    browserState = BrowserSessionInfo(url: lastBrowserState.url, title: lastBrowserState.title)
                } else {
                    let newBrowser = NodeBrowserExecutor(nodeURL: configuration.nodeURL, executorURL: configuration.executorURL)
                    browser = newBrowser
                    browserState = try await newBrowser.start(configuration: configuration.browser)
                    self.executor = newBrowser
                    self.timeline.append(TimelineItem(title: "Browser started", detail: browserState.url, risk: nil))
                }
                self.lastBrowserState = BrowserState(url: browserState.url, title: browserState.title)
                let response = try await backend.startComputerUse(
                    instruction: instruction,
                    initialURL: configuration.browser.initialURL,
                    allowedOrigins: configuration.browser.allowedOrigins,
                    currentURL: browserState.url,
                    currentTitle: browserState.title,
                    serviceToken: token
                )
                self.sessionID = response.sessionID
                self.append(response.step, prefix: "Plan")
                try await self.execute(response)
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func execute(_ response: ComputerUseResponse) async throws {
        if response.done {
            finish(message: response.message ?? "Task completed.", keepBrowser: true)
            return
        }
        guard let step = response.step, let executor, let sessionID,
              let token = keychain.loadServiceToken(), !token.isEmpty else {
            throw BackendError.invalidResponse
        }
        if step.risk == "needs_user_approval" && step.status == "awaiting_approval" {
            pendingApproval = PendingApproval(
                sessionID: sessionID,
                stepID: step.id,
                codeHash: step.codeHash,
                browserStateHash: step.browserStateHash,
                summary: step.summary,
                code: step.code
            )
            panel.show()
            return
        }
        timeline.append(TimelineItem(title: "Executing", detail: step.summary, risk: step.risk))
        let execution = try await executor.execute(module: step.code)
        lastBrowserState = BrowserState(url: execution.browser.url, title: execution.browser.title)
        let screenshot = try executor.consumeScreenshot(from: execution)
        let resultJSON = try JSONEncoder().encode(BrowserExecutionPayload(execution))
        let next = try await backend.submitComputerUseResult(
            sessionID: sessionID,
            stepID: step.id,
            resultJSON: resultJSON,
            screenshot: screenshot,
            currentURL: execution.browser.url,
            currentTitle: execution.browser.title,
            serviceToken: token
        )
        append(next.step, prefix: "Next plan")
        try await execute(next)
    }

    private func append(_ step: ComputerUseStepResponse?, prefix: String) {
        guard let step else { return }
        timeline.append(TimelineItem(title: prefix, detail: step.summary, risk: step.risk))
    }

    private func finish(message: String, keepBrowser: Bool = false) {
        task = nil
        isRunning = false
        pendingApproval = nil
        timeline.append(TimelineItem(title: "Finished", detail: message, risk: nil))
        if !keepBrowser, let executor {
            Task { await executor.stop() }
            self.executor = nil
            self.lastBrowserState = nil
        }
        sessionID = nil
        panel.show()
    }

    private func fail(_ message: String) {
        errorMessage = message
        timeline.append(TimelineItem(title: "Blocked", detail: message, risk: "prohibited"))
        finish(message: message)
    }
}

private struct BrowserExecutionPayload: Codable {
    var ok: Bool
    var value: BrowserTableResult?
    var text: [String]?
    var browser: BrowserState
    var error: BrowserResultError?

    init(_ result: BrowserExecutorResult) {
        ok = result.ok
        value = result.value
        text = result.text
        browser = result.browser
        error = result.error
    }
}

private struct ComputerUseLocalConfiguration {
    let browser: BrowserConfiguration
    let nodeURL: URL
    let executorURL: URL

    static func load() throws -> ComputerUseLocalConfiguration {
        let initialURLString = Bundle.main.object(forInfoDictionaryKey: "COMPUTER_USE_INITIAL_URL") as? String
            ?? "https://www.google.com"
        guard let initialURL = URL(string: initialURLString),
              let scheme = initialURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              initialURL.host != nil else {
            throw BackendError.invalidResponse
        }
        let configuredOrigins = (Bundle.main.object(forInfoDictionaryKey: "COMPUTER_USE_ALLOWED_ORIGINS") as? String)?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let allowedOrigins = configuredOrigins?.isEmpty == false ? configuredOrigins! : ["*"]
        let nodePath = (Bundle.main.object(forInfoDictionaryKey: "COMPUTER_USE_NODE_PATH") as? String)
            ?? "/opt/homebrew/bin/node"
        guard let executorURL = Bundle.main.url(forResource: "index", withExtension: "js", subdirectory: "computer-use-executor") else {
            throw BrowserExecutorError.executorNotFound(URL(fileURLWithPath: "computer-use-executor.js"))
        }
        return ComputerUseLocalConfiguration(
            browser: BrowserConfiguration(
                initialURL: initialURL,
                allowedOrigins: allowedOrigins,
                artifactDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("local-whisper-computer-use-\(UUID().uuidString)"),
                profileDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("local_whisper/computer-use-profile")
            ),
            nodeURL: URL(fileURLWithPath: nodePath),
            executorURL: executorURL
        )
    }
}

private extension URL {
    var origin: String? {
        guard let scheme, let host else { return nil }
        let portPart = port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(portPart)"
    }
}

@MainActor
private final class ComputerUsePanelController {
    var onApprove: (() -> Void)?
    var onDeny: (() -> Void)?
    var onCancel: (() -> Void)?
    var onClearProfile: (() -> Void)?
    private var window: NSPanel?

    func setContent(_ coordinator: ComputerUseCoordinator) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Computer Use"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ComputerUsePanelView(coordinator: coordinator, controller: self))
        window = panel
    }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ComputerUsePanelView: View {
    let coordinator: ComputerUseCoordinator
    let controller: ComputerUsePanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Computer use")
                .font(.title2.bold())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(coordinator.timeline) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.headline)
                            Text(item.detail).font(.callout)
                            if let risk = item.risk {
                                Text(risk.replacingOccurrences(of: "_", with: " ").uppercased())
                                    .font(.caption.bold())
                                    .foregroundStyle(.red)
                            }
                        }
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
            }
            if let approval = coordinator.pendingApproval {
                Text("Approval required: \(approval.summary)")
                    .font(.headline)
                    .foregroundStyle(.red)
                ScrollView {
                    Text(approval.code)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                HStack {
                    Button("Deny", role: .cancel) { controller.onDeny?() }
                    Button("Approve") { controller.onApprove?() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            HStack {
                Button("Cancel task", role: .cancel) { controller.onCancel?() }
                Button("Clear browser sign-in", role: .destructive) { controller.onClearProfile?() }
                    .disabled(coordinator.isRunning)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 580)
    }
}
