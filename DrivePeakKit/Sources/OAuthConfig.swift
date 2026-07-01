import Foundation

/// Loads Google OAuth client configuration from bundled GoogleOAuth.plist.
public struct OAuthConfig {
    /// The OAuth client ID from the bundled plist.
    public let clientId: String

    /// Loads OAuthConfig from GoogleOAuth.plist in the bundle's Resources.
    /// - Returns: OAuthConfig with the client_id from the plist.
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

        return OAuthConfig(clientId: clientId)
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
