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

    public init(backend: KeychainBackend = SystemKeychain()) {
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

/// Real Keychain backed by the app's first entitled keychain-access-group.
///
/// We intentionally omit `kSecAttrAccessGroup` from the query. When omitted,
/// Keychain Services defaults to the process's first entitled access group —
/// which is `$(AppIdentifierPrefix)com.drivepeak.shared` from the entitlements.
/// That resolves at runtime to `<TeamID>.com.drivepeak.shared`, the exact
/// team-prefixed string the entitlement actually grants.
///
/// Passing the bare, unqualified string "com.drivepeak.shared" instead would
/// never match an entitled group (they all carry the team prefix), causing
/// SecItemAdd to return errSecMissingEntitlement (-34018) and silently breaking
/// Tier 1 on any signed build.
///
/// ponytail: thin shim, no unit test; logic lives in TokenStore.
public final class SystemKeychain: KeychainBackend {
    public init() {}

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: account]
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

    public enum KeychainError: LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .status(let s): return "Keychain operation failed (OSStatus \(s))."
            }
        }
    }
}
