import Foundation

/// OAuth tokens persisted by the app and read by the extension.
/// `refreshToken` is long-lived → lives in the Keychain (see TokenStore).
public struct Tokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiry: Date
    public let email: String?

    public init(accessToken: String, refreshToken: String, expiry: Date, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiry = expiry
        self.email = email
    }

    /// True once the access token is at/near its expiry (refresh needed).
    /// Applies a 30s skew buffer: we treat the token as expired slightly early
    /// so a token about to expire mid-request (or a small backward clock drift)
    /// triggers a refresh rather than a rejected call.
    public var isExpired: Bool { expiry.timeIntervalSinceNow <= 30 }
}
