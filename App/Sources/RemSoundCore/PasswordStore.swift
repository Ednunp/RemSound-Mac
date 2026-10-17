import Foundation
import Security

/// Keeps the shared network password out of preferences, profiles, logs and DAW state.
public final class PasswordStore {
    private let service: String
    private let account: String
    private let ephemeral: Bool
    private var temporaryPassword: String?

    public init(service: String = "org.remsound.mac.shared-password", account: String = "default") {
        self.service = service
        self.account = account
        ephemeral = false
    }

    /// An isolated run keeps passwords only in memory and never opens the user's Keychain.
    public init(ephemeral: Bool) {
        service = "org.remsound.mac.shared-password"
        account = "default"
        self.ephemeral = ephemeral
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Bounds UTF-8 materialization to a positive cap of at most 1024 bytes.
    /// Security may already have allocated its returned Data; this is not an OS allocation limit.
    public func load(maximumUTF8Bytes: Int) throws -> String? {
        guard (1...Self.maximumBoundedPasswordBytes).contains(maximumUTF8Bytes) else { throw PasswordStoreError(status: errSecParam) }
        return try readPassword(limit: maximumUTF8Bytes)
    }
    private static let maximumBoundedPasswordBytes = 1024

    public func load() throws -> String? { try readPassword(limit: nil) }

    private func readPassword(limit: Int?) throws -> String? {
        if ephemeral {
            if let limit, let value = temporaryPassword, value.utf8.prefix(limit + 1).count > limit { throw PasswordStoreError(status: errSecParam) }
            return temporaryPassword
        }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PasswordStoreError(status: status) }
        if let limit, data.count > limit { throw PasswordStoreError(status: errSecParam) }
        guard let password = String(data: data, encoding: .utf8) else {
            throw PasswordStoreError(status: status)
        }
        return password
    }

    public func save(_ password: String) throws {
        precondition(!password.isEmpty)
        if ephemeral { temporaryPassword = password; return }
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw PasswordStoreError(status: addStatus) }
            return
        }
        throw PasswordStoreError(status: status)
    }

    public func delete() throws {
        if ephemeral { temporaryPassword = nil; return }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordStoreError(status: status)
        }
    }
}

public struct PasswordStoreError: LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        "Mac Keychain operation failed (\(status))."
    }
}
