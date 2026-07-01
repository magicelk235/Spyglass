import Foundation

/// Loads Google OAuth client configuration from bundled GoogleOAuth.plist.
public struct OAuthConfig {
    /// The OAuth client ID from the bundled plist.
    public let clientId: String
    /// The OAuth client secret. Google-issued "Desktop app" clients get a secret
    /// and require it in the token/refresh exchange *even with PKCE* — only true
    /// public clients (mobile) may omit it. Optional so Tier 0 still loads if the
    /// plist has no secret; nil just means the token exchange will 400.
    public let clientSecret: String?

    /// Loads OAuthConfig from GoogleOAuth.plist in the bundle's Resources.
    /// - Returns: OAuthConfig with the client_id (and optional client_secret).
    /// - Throws: If the plist is missing, unreadable, or lacks CLIENT_ID key.
    public static func load(from bundle: Bundle = .main) throws -> OAuthConfig {
        guard let plistURL = bundle.url(forResource: "GoogleOAuth", withExtension: "plist") else {
            throw OAuthConfigError.plistNotFound
        }

        let data = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw OAuthConfigError.invalidPlistFormat
        }

        guard let clientId = plist["CLIENT_ID"] as? String else {
            throw OAuthConfigError.missingClientId
        }

        return OAuthConfig(clientId: clientId,
                           clientSecret: plist["CLIENT_SECRET"] as? String)
    }

    /// Convenience: the client_id, or nil if the plist is absent/malformed.
    /// This is the entry point call sites use — a missing config just disables
    /// the authenticated tier rather than throwing.
    public static func clientID(bundle: Bundle = .main) -> String? {
        (try? load(from: bundle))?.clientId
    }

    /// Convenience: the client_secret, or nil if absent.
    public static func clientSecret(bundle: Bundle = .main) -> String? {
        (try? load(from: bundle))?.clientSecret
    }
}

/// Errors that can occur when loading OAuth configuration.
public enum OAuthConfigError: Error, LocalizedError {
    case plistNotFound
    case invalidPlistFormat
    case missingClientId

    public var errorDescription: String? {
        switch self {
        case .plistNotFound:
            return "GoogleOAuth.plist not found in bundle resources"
        case .invalidPlistFormat:
            return "GoogleOAuth.plist has invalid format"
        case .missingClientId:
            return "CLIENT_ID key not found in GoogleOAuth.plist"
        }
    }
}
