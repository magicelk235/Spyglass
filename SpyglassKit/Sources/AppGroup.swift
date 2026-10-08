import Foundation

/// The App Group shared by the app and the Quick Look extension.
public enum AppGroup {

    /// Team-prefixed, because since macOS 15 a sandboxed extension may only
    /// open a `group.*` container that its provisioning profile authorizes,
    /// and Developer ID profiles carry no App Group entry. A group named after
    /// the team needs no profile entry. Must match both entitlements files
    /// (AppGroupTests checks).
    public static let identifier = "V8K8L3ZSD5.com.spyglass.shared"

    /// The group used up to 1.0. The extension can't read it, so the app
    /// moves the license and cached previews out of it once (`LegacyGroupMigration`).
    public static let legacyIdentifier = "group.com.spyglass.shared"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
