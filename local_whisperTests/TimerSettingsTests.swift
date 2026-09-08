import XCTest
@testable import local_whisper

@MainActor
final class TimerSettingsTests: XCTestCase {
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "TimerSettingsTests.\(UUID().uuidString)")!
        TimerSettings.defaults = testDefaults
    }

    override func tearDown() {
        TimerSettings.defaults = .standard
        testDefaults = nil
        super.tearDown()
    }

    func testCompletionSoundIsEnabledByDefault() {
        XCTAssertTrue(TimerSettings.completionSoundEnabled)
    }

    func testCompletionSoundSettingPersists() {
        TimerSettings.completionSoundEnabled = false

        XCTAssertFalse(TimerSettings.completionSoundEnabled)
        XCTAssertFalse(testDefaults.bool(forKey: "timer.completionSoundEnabled"))
    }
}
