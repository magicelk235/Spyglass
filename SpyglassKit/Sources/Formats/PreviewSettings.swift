import Foundation

/// User preferences for format previews. The app writes them to a JSON file
/// in Application Support; the extension reads that file through a read-only
/// sandbox exception. The App Group can't carry them: macOS denies the
/// extension reads of the group's preferences (app data protection).
public struct PreviewSettings: Codable, Equatable, Sendable {

    public enum Theme: String, Codable, CaseIterable, Sendable {
        case system, light, dark
    }

    public static let fontSizeRange: ClosedRange<Double> = 9...24

    public var theme: Theme = .system
    public var codeFontSize: Double = 12
    public var disabledGroups: Set<FormatGroup> = []

    public init() {}

    /// Each field falls back to its default on its own, so settings written by
    /// an older version keep the values they do have.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? .system
        codeFontSize = (try? c.decodeIfPresent(Double.self, forKey: .codeFontSize)) ?? 12
        disabledGroups = (try? c.decodeIfPresent(Set<FormatGroup>.self, forKey: .disabledGroups)) ?? []
    }

    public func isEnabled(_ group: FormatGroup) -> Bool {
        !disabledGroups.contains(group)
    }

    /// `~/Library/Application Support/Spyglass/preview-settings.json` under
    /// the real home folder. Inside the sandbox `homeDirectoryForCurrentUser`
    /// points into the extension's container, so ask the user database.
    public static var defaultURL: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } }
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Spyglass/preview-settings.json")
    }

    /// Missing or unreadable settings load as defaults, so a bad write can
    /// never stop previews from working.
    public static func load(from url: URL = defaultURL) -> PreviewSettings {
        guard let data = try? Data(contentsOf: url),
              var settings = try? JSONDecoder().decode(PreviewSettings.self, from: data)
        else { return PreviewSettings() }
        settings.codeFontSize = settings.codeFontSize.clamped(to: fontSizeRange)
        return settings
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
