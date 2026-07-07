import Foundation
import CryptoKit
import Security

/// PKCE (RFC 7636) verifier/challenge pair and Google OAuth URL assembly.
/// Pure and deterministic given the verifier, so the challenge derivation is
/// unit-tested; only the random verifier bytes vary.
public struct PKCE {
    public let verifier: String
    public let challenge: String

    public static func generate() -> PKCE {
        // 32 random bytes → 43-char base64url verifier (RFC 7636 unreserved).
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "PKCE: secure RNG failed")
        let verifier = base64url(Data(bytes))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return PKCE(verifier: verifier, challenge: base64url(Data(digest)))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A random URL-safe token for the OAuth `state` parameter (CSRF defense).
    /// 32 bytes -> 43-char base64url, same generator as the PKCE verifier.
    public static func makeState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "state: secure RNG failed")
        return base64url(Data(bytes))
    }

    public static func makeAuthURL(clientID: String, redirectURI: String, challenge: String, state: String) -> URL {
        var c = URLComponents(string: GoogleOAuthEndpoints.auth)!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GoogleOAuthEndpoints.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        return c.url!
    }
}

public enum GoogleOAuthEndpoints {
    public static let auth = "https://accounts.google.com/o/oauth2/auth"
    public static let token = "https://oauth2.googleapis.com/token"
    public static let userinfo = "https://www.googleapis.com/oauth2/v3/userinfo"
    public static let revoke = "https://oauth2.googleapis.com/revoke"
    public static let scopes = [
        "https://www.googleapis.com/auth/drive.readonly",
        "https://www.googleapis.com/auth/userinfo.email",
    ]
}
