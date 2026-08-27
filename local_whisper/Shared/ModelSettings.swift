import Foundation

enum ModelSettings {
    static let chatDefault = "gpt-4o-mini"
    static let transcribeDefault = "gpt-4o-mini-transcribe"

    private static let chatKey = "openai.chatModel"
    private static let transcribeKey = "openai.transcribeModel"

    static var chat: String {
        get { UserDefaults.standard.string(forKey: chatKey) ?? chatDefault }
        set { UserDefaults.standard.set(newValue, forKey: chatKey) }
    }

    static var transcribe: String {
        get { UserDefaults.standard.string(forKey: transcribeKey) ?? transcribeDefault }
        set { UserDefaults.standard.set(newValue, forKey: transcribeKey) }
    }
}
