import XCTest
@testable import local_whisper

@MainActor
final class VoiceChatTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "VoiceChatTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        ConversationIDSettings.defaults = testDefaults
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        ConversationIDSettings.defaults = .standard
        testDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testStoppingRecordingTranscribesBeforeCompleting() async throws {
        let backend = ChatBackendFake()
        let capture = ChatCaptureFake()
        let chat = VoiceChat(
            backend: backend,
            tokenState: ServiceTokenState(keychain: ChatKeychain()),
            toast: ToastPresenter(),
            capture: capture
        )
        var openWindowCount = 0
        chat.openWindow = { openWindowCount += 1 }
        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-chat-test.m4a")
        try Data("audio".utf8).write(to: recordingURL)
        capture.finishedURLs = [recordingURL]

        chat.toggle()
        XCTAssertEqual(openWindowCount, 0)
        chat.toggle()

        for _ in 0..<20 where chat.phase != .response {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(backend.calls, ["transcribe", "complete:Bonjour?"])
        XCTAssertEqual(chat.response, "Answer")
        XCTAssertEqual(openWindowCount, 1)
    }

    func testConversationIDPersistsAndIsForwardedOnNextCompletion() async throws {
        let backend = ChatBackendFake()
        let capture = ChatCaptureFake()
        let chat = VoiceChat(
            backend: backend,
            tokenState: ServiceTokenState(keychain: ChatKeychain()),
            toast: ToastPresenter(),
            capture: capture
        )
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-chat-first-turn.m4a")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-chat-second-turn.m4a")
        try Data("audio".utf8).write(to: firstURL)
        try Data("audio".utf8).write(to: secondURL)
        capture.finishedURLs = [firstURL, secondURL]

        chat.toggle()
        chat.toggle()
        for _ in 0..<40 where chat.phase != .response {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(ConversationIDSettings.activeID, "conversation-1")
        for _ in 0..<40 where chat.isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }

        chat.toggle()
        chat.toggle()
        for _ in 0..<40 where chat.phase != .response || backend.completionIDs.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(backend.completionIDs, [nil, "conversation-1"])
        XCTAssertEqual(ConversationIDSettings.activeID, "conversation-2")
        XCTAssertEqual(backend.calls, [
            "transcribe", "complete:Bonjour?", "transcribe", "complete:Bonjour?",
        ])
    }

    func testFailedFirstCompletionDoesNotPersistConversationID() async throws {
        let backend = ChatBackendFake()
        backend.shouldFailCompletion = true
        let capture = ChatCaptureFake()
        let chat = VoiceChat(
            backend: backend,
            tokenState: ServiceTokenState(keychain: ChatKeychain()),
            toast: ToastPresenter(),
            capture: capture
        )
        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-chat-failed-turn.m4a")
        try Data("audio".utf8).write(to: recordingURL)
        capture.finishedURLs = [recordingURL]

        chat.toggle()
        chat.toggle()
        for _ in 0..<40 where chat.phase != .failed {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNil(ConversationIDSettings.activeID)
        XCTAssertEqual(backend.completionIDs, [nil])
    }

    func testCancellingRecordingDoesNotSubmit() {
        let backend = ChatBackendFake()
        let capture = ChatCaptureFake()
        let chat = VoiceChat(
            backend: backend,
            tokenState: ServiceTokenState(keychain: ChatKeychain()),
            toast: ToastPresenter(),
            capture: capture
        )

        chat.toggle()
        chat.cancelRecording(showToast: false)

        XCTAssertEqual(capture.cancelCount, 1)
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertEqual(chat.phase, .idle)
    }
}

@MainActor
private final class ChatCaptureFake: VoiceCapturing {
    var onRecordingFinished: ((URL) -> Void)?
    var onRecordingStateChanged: ((Bool) -> Void)?
    var finishedURLs: [URL] = []
    var cancelCount = 0
    private var recording = false

    func toggle(prompt: String) {
        if recording {
            recording = false
            onRecordingStateChanged?(false)
            if !finishedURLs.isEmpty {
                onRecordingFinished?(finishedURLs.removeFirst())
            }
        } else {
            recording = true
            onRecordingStateChanged?(true)
        }
    }

    func cancel(showToast: Bool) {
        guard recording else { return }
        recording = false
        cancelCount += 1
        onRecordingStateChanged?(false)
    }
}

private final class ChatBackendFake: BackendClienting, @unchecked Sendable {
    var calls: [String] = []
    var completionIDs: [String?] = []
    var shouldFailCompletion = false

    func extractText(fromJPEG data: Data, serviceToken: String) async throws -> String? { nil }
    func fetchEncouragement(serviceToken: String) async throws -> String { "" }
    func transcribeAudio(at fileURL: URL, serviceToken: String) async throws -> String { "" }

    func transcribeSourceAudio(at fileURL: URL, serviceToken: String) async throws -> String {
        calls.append("transcribe")
        return "Bonjour?"
    }

    func complete(
        text: String,
        conversationID: String?,
        serviceToken: String
    ) async throws -> ChatCompletionResult {
        calls.append("complete:\(text)")
        completionIDs.append(conversationID)
        if shouldFailCompletion {
            throw BackendError.network("Test completion failure")
        }
        return ChatCompletionResult(
            text: "Answer",
            conversationID: "conversation-\(completionIDs.count)"
        )
    }
}

private struct ChatKeychain: Keychaining, Sendable {
    var hasServiceToken: Bool { true }
    func loadServiceToken() -> String? { "test-token" }
    func saveServiceToken(_ token: String) -> Bool { true }
}
