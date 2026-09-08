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

    func testStartOrExtendStartsWhenStopped() {
        let countdown = Countdown(toast: ToastPresenter())

        countdown.startOrExtend()

        XCTAssertTrue(countdown.isRunning)
        countdown.cancel()
    }

    func testStartOrExtendAddsFiveMinutesWhenRunning() {
        let countdown = Countdown(toast: ToastPresenter())
        countdown.start()
        let initial = seconds(from: countdown.remainingLabel)

        countdown.startOrExtend()

        let extended = seconds(from: countdown.remainingLabel)
        XCTAssertGreaterThanOrEqual(extended - initial, 299)
        countdown.cancel()
    }

    func testRepeatedExtensionsAccumulateWithoutCompletionSound() {
        var soundPlayCount = 0
        let countdown = Countdown(toast: ToastPresenter()) {
            soundPlayCount += 1
        }
        countdown.start()
        let initial = seconds(from: countdown.remainingLabel)

        countdown.startOrExtend()
        countdown.startOrExtend()

        let extended = seconds(from: countdown.remainingLabel)
        XCTAssertGreaterThanOrEqual(extended - initial, 598)
        XCTAssertEqual(soundPlayCount, 0)
        countdown.cancel()
    }

    private func seconds(from label: String?) -> Int {
        let parts = label!.split(separator: ":").map { Int($0)! }
        return parts[0] * 60 + parts[1]
    }
}
