import Foundation

enum ModelSettings {
    static let chatDefault = "gpt-4o-mini"
    static let transcribeDefault = "gpt-4o-mini-transcribe"

    private static let chatKey = "openai.chatModel"
    private static let transcribeKey = "openai.transcribeModel"
    private static let rawTelemetryKey = "telemetry.rawPayloads"

    static var chat: String {
        get { UserDefaults.standard.string(forKey: chatKey) ?? chatDefault }
        set { UserDefaults.standard.set(newValue, forKey: chatKey) }
    }

    static var transcribe: String {
        get { UserDefaults.standard.string(forKey: transcribeKey) ?? transcribeDefault }
        set { UserDefaults.standard.set(newValue, forKey: transcribeKey) }
    }

    static var rawTelemetryEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: rawTelemetryKey) }
        set { UserDefaults.standard.set(newValue, forKey: rawTelemetryKey) }
    }
}
