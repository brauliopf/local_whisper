import XCTest
@testable import local_whisper

@MainActor
final class CountdownTests: XCTestCase {
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "CountdownTests.\(UUID().uuidString)")!
        TimerSettings.defaults = testDefaults
    }

    override func tearDown() {
        TimerSettings.defaults = .standard
        testDefaults = nil
        super.tearDown()
    }

    func testCompletionPlaysSoundWhenEnabled() {
        var soundPlayCount = 0
        let countdown = Countdown(toast: ToastPresenter()) {
            soundPlayCount += 1
        }

        countdown.start()
        countdown.complete()

        XCTAssertEqual(soundPlayCount, 1)
    }

    func testCompletionDoesNotPlaySoundWhenDisabled() {
        TimerSettings.completionSoundEnabled = false
        var soundPlayCount = 0
        let countdown = Countdown(toast: ToastPresenter()) {
            soundPlayCount += 1
        }

        countdown.start()
        countdown.complete()

        XCTAssertEqual(soundPlayCount, 0)
    }

    func testCompletionUsesCurrentSoundSetting() {
        var soundPlayCount = 0
        let countdown = Countdown(toast: ToastPresenter()) {
            soundPlayCount += 1
        }

        countdown.start()
        TimerSettings.completionSoundEnabled = false
        countdown.complete()

        XCTAssertEqual(soundPlayCount, 0)
    }
}
