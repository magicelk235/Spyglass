import Foundation

/// User preferences for format previews. The app writes them to the shared
/// App Group defaults; the extension only reads them.
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

    private static let key = "previewSettings"

    /// Missing or unreadable settings load as defaults, so a bad write can
    /// never stop previews from working.
    public static func load(groupID: String = AppGroup.identifier) -> PreviewSettings {
        guard let data = UserDefaults(suiteName: groupID)?.data(forKey: key),
              var settings = try? JSONDecoder().decode(PreviewSettings.self, from: data)
        else { return PreviewSettings() }
        settings.codeFontSize = settings.codeFontSize.clamped(to: fontSizeRange)
        return settings
    }

    public func save(groupID: String = AppGroup.identifier) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: groupID)?.set(data, forKey: Self.key)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
