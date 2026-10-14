import Foundation

@MainActor
@Observable
final class ServiceTokenState {
    private let keychain: any Keychaining
    private(set) var token: String?

    init(keychain: any Keychaining) {
        self.keychain = keychain
        self.token = keychain.loadServiceToken()
    }

    var hasToken: Bool { token != nil }

    @discardableResult
    func save(_ value: String) -> Bool {
        guard keychain.saveServiceToken(value) else { return false }
        token = keychain.loadServiceToken()
        return token != nil
    }

    func refresh() {
        token = keychain.loadServiceToken()
    }
}
