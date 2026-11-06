import Foundation

@MainActor
enum ConversationIDSettings {
    static let activeIDKey = "chat.activeConversationID"
    static var defaults = UserDefaults.standard

    static var activeID: String? {
        get {
            guard let value = defaults.string(forKey: activeIDKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                return nil
            }
            return value
        }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else {
                defaults.removeObject(forKey: activeIDKey)
                return
            }
            defaults.set(value, forKey: activeIDKey)
        }
    }
}
