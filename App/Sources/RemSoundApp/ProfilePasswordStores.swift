import Foundation
import RemSoundCore

// App roles select Core credential stores; no query occurs during construction.
final class ProfilePasswordStores {
    enum Role: Hashable { case audio, browser }
    static func service(for role: Role) -> String {
        switch role {
        case .audio: return "org.remsound.mac.shared-password"
        case .browser: return "org.remsound.mac.browser-listener-password"
        }
    }
    private struct Key: Hashable { let role: Role, account: String }
    private var passwords = [Key: PasswordStore]()
    func store(account: String = "default", role: Role = .audio, isolated: Bool) -> PasswordStore {
        guard isolated else { return PasswordStore(service: Self.service(for: role), account: account) }
        let key = Key(role: role, account: account)
        if let store = passwords[key] { return store }
        let store = PasswordStore(ephemeral: true); passwords[key] = store; return store
    }
}
