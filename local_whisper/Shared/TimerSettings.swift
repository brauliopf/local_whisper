import Foundation

enum TimerSettings {
    static let defaultMinutes = 20
    static let minMinutes = 1
    static let maxMinutes = 1440

    private static let minutesKey = "timer.countdownMinutes"
    private static let completionSoundEnabledKey = "timer.completionSoundEnabled"

    static var defaults = UserDefaults.standard

    static var minutes: Int {
        get {
            let stored = defaults.object(forKey: minutesKey) as? Int
            return clamp(stored ?? defaultMinutes)
        }
        set {
            defaults.set(clamp(newValue), forKey: minutesKey)
        }
    }

    static var completionSoundEnabled: Bool {
        get {
            guard defaults.object(forKey: completionSoundEnabledKey) != nil else { return true }
            return defaults.bool(forKey: completionSoundEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: completionSoundEnabledKey)
        }
    }

    static var duration: TimeInterval {
        TimeInterval(minutes * 60)
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, minMinutes), maxMinutes)
    }
}
