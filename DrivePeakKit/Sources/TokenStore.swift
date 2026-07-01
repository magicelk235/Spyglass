import Foundation
import Security

/// Storage backend abstraction so the encode/decode path is unit-testable
/// without the entitlement-gated system Keychain.
public protocol KeychainBackend {
    func set(_ data: Data, account: String) throws
    func get(account: String) -> Data?
    func delete(account: String) throws
}

public struct TokenStore {
    private static let account = "google-oauth"
    private let backend: KeychainBackend

    public init(backend: KeychainBackend = SystemKeychain(group: "com.drivepeak.shared")) {
        self.backend = backend
    }

    public func save(_ tokens: Tokens) throws {
        try backend.set(try JSONEncoder().encode(tokens), account: Self.account)
    }

    public func load() -> Tokens? {
        guard let data = backend.get(account: Self.account) else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    public func clear() throws {
        try backend.delete(account: Self.account)
    }
}

/// Real Keychain backed by a shared access group. Requires the
/// keychain-access-groups entitlement ($(DEVELOPMENT_TEAM).com.drivepeak.shared),
/// which needs a paid Apple Developer Team ID to sign — exercised manually once
/// the account lands. ponytail: thin shim, no unit test; logic lives in TokenStore.
public final class SystemKeychain: KeychainBackend {
    private let group: String
    public init(group: String) { self.group = group }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: group]
    }

    public func set(_ data: Data, account: String) throws {
        try delete(account: account)
        var q = baseQuery(account)
        q[kSecValueData as String] = data
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func get(account: String) -> Data? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    public enum KeychainError: Error { case status(OSStatus) }
}
