import Foundation

enum TimerSettings {
    static let defaultMinutes = 20
    static let minMinutes = 1
    static let maxMinutes = 1440

    private static let minutesKey = "timer.countdownMinutes"

    static var minutes: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: minutesKey) as? Int
            return clamp(stored ?? defaultMinutes)
        }
        set {
            UserDefaults.standard.set(clamp(newValue), forKey: minutesKey)
        }
    }

    static var duration: TimeInterval {
        TimeInterval(minutes * 60)
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, minMinutes), maxMinutes)
    }
}
