import XCTest
@testable import local_whisper

@MainActor
final class VoiceChatTests: XCTestCase {
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
        capture.finishedURL = recordingURL

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
    var finishedURL: URL?
    var cancelCount = 0
    private var recording = false

    func toggle(prompt: String) {
        if recording {
            recording = false
            onRecordingStateChanged?(false)
            if let finishedURL {
                onRecordingFinished?(finishedURL)
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

    func extractText(fromJPEG data: Data, serviceToken: String) async throws -> String? { nil }
    func fetchEncouragement(serviceToken: String) async throws -> String { "" }
    func transcribeAudio(at fileURL: URL, serviceToken: String) async throws -> String { "" }

    func transcribeSourceAudio(at fileURL: URL, serviceToken: String) async throws -> String {
        calls.append("transcribe")
        return "Bonjour?"
    }

    func complete(text: String, serviceToken: String) async throws -> String {
        calls.append("complete:\(text)")
        return "Answer"
    }
}

private struct ChatKeychain: Keychaining, Sendable {
    var hasServiceToken: Bool { true }
    func loadServiceToken() -> String? { "test-token" }
    func saveServiceToken(_ token: String) -> Bool { true }
}
