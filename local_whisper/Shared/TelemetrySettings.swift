import Foundation

enum TelemetrySettings {
    private static let rawTelemetryKey = "telemetry.rawPayloads"

    static var rawTelemetryEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: rawTelemetryKey) }
        set { UserDefaults.standard.set(newValue, forKey: rawTelemetryKey) }
    }
}
