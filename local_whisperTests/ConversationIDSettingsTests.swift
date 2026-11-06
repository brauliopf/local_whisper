import XCTest
@testable import local_whisper

@MainActor
final class ConversationIDSettingsTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ConversationIDSettingsTests.\(UUID().uuidString)"
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

    func testActiveIDPersistsAndCanBeCleared() {
        ConversationIDSettings.activeID = "conversation-123"
        XCTAssertEqual(ConversationIDSettings.activeID, "conversation-123")
        XCTAssertEqual(
            testDefaults.string(forKey: ConversationIDSettings.activeIDKey),
            "conversation-123"
        )

        ConversationIDSettings.activeID = nil

        XCTAssertNil(ConversationIDSettings.activeID)
        XCTAssertNil(testDefaults.object(forKey: ConversationIDSettings.activeIDKey))
    }

    func testEmptyActiveIDIsTreatedAsUnset() {
        ConversationIDSettings.activeID = "  \n"

        XCTAssertNil(ConversationIDSettings.activeID)
        XCTAssertNil(testDefaults.object(forKey: ConversationIDSettings.activeIDKey))
    }
}
