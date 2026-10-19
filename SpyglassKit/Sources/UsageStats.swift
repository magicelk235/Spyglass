import Foundation

/// How many previews this Mac showed per format over the last week.
///
/// The Quick Look extension records one count per preview; the app reads the
/// week to show the user what Spyglass did for them and to tag the checkout
/// link when they press Buy. Only counts per day and per format are kept (no
/// file names, no paths), and only for the last seven days.
///
/// The counts live in a JSON file inside the extension's own sandbox
/// container: the extension may not write the shared App Group (preferences
/// writes are rejected), but it can write its own container, and the app,
/// which isn't sandboxed and is signed by the same team, can read it there.
public struct UsageStats {

    static let driveKey = "drive"
    static let days = 7

    let fileURL: URL
    private let calendar: Calendar

    init(fileURL: URL, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.calendar = calendar
    }

    private static let relativePath = "Library/Application Support/Spyglass/usage.json"
    private static let extensionBundleID = "com.spyglass.app.preview"

    /// For the Quick Look extension: its home is its sandbox container.
    public static func inExtension() -> UsageStats {
        UsageStats(fileURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relativePath))
    }

    /// For the app: the same file, found inside the extension's container.
    public static func inApp() -> UsageStats {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return UsageStats(fileURL: URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Containers/\(extensionBundleID)/Data")
            .appendingPathComponent(relativePath))
    }

    // MARK: - Recording (Quick Look extension)

    public func record(_ group: FormatGroup, now: Date = Date()) {
        increment(group.rawValue, now: now)
    }

    /// A Google Drive file (stub or Drive bookmark) was previewed.
    public func recordDrive(now: Date = Date()) {
        increment(Self.driveKey, now: now)
    }

    /// Read-modify-write without a lock: Quick Look previews one file at a
    /// time, and a lost count in a rare race doesn't matter for these numbers.
    private func increment(_ category: String, now: Date) {
        let today = dayKey(now)
        let oldest = dayKey(calendar.date(byAdding: .day, value: -(Self.days - 1), to: now) ?? now)
        var all = stored().filter { $0.key >= oldest }
        all[today, default: [:]][category, default: 0] += 1
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Reading (app)

    public func week(now: Date = Date()) -> Week {
        let oldest = dayKey(calendar.date(byAdding: .day, value: -(Self.days - 1), to: now) ?? now)
        var counts: [String: Int] = [:]
        for (day, byCategory) in stored() where day >= oldest {
            for (category, n) in byCategory { counts[category, default: 0] += n }
        }
        return Week(counts: counts)
    }

    var storedDays: Int { stored().count }

    private func stored() -> [String: [String: Int]] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: Int]].self, from: data)) ?? [:]
    }

    /// "2026-10-09" in the user's calendar; sorts like the dates it names.
    private func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public struct Week: Equatable, Sendable {
        let counts: [String: Int]

        public var total: Int { counts.values.reduce(0, +) }
        public var drive: Int { counts[UsageStats.driveKey] ?? 0 }

        public func count(_ group: FormatGroup) -> Int { counts[group.rawValue] ?? 0 }

        /// Most-previewed formats first; equal counts in name order so the
        /// list is stable.
        public func topFormats(_ n: Int) -> [(group: FormatGroup, count: Int)] {
            FormatGroup.allCases
                .map { ($0, count($0)) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.rawValue < $1.0.rawValue }
                .prefix(n)
                .map { (group: $0.0, count: $0.1) }
        }

        /// The most-used category, Google Drive included; nil with no previews.
        var topCategory: String? {
            counts.filter { $0.value > 0 }
                .max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        }

        /// "This week: 143 previews. Markdown 61, Code 40, Notebooks 12."
        public var summary: String? {
            let top = topFormats(3)
            guard total > 0, !top.isEmpty else { return nil }
            let noun = total == 1 ? "preview" : "previews"
            let list = top.map { "\($0.group.shortName) \($0.count)" }.joined(separator: ", ")
            return "This week: \(total.formatted()) \(noun). \(list)."
        }
    }
}

/// The Gumroad checkout link the app opens when the user presses Buy.
///
/// `wanted=true` skips the product page and opens checkout. The UTM tags are
/// the only usage data Spyglass ever shares, and only on that click: which
/// button, how far into the trial, the most-used format, and a coarse bucket
/// of this week's previews. Gumroad files each tag combination as a UTM link
/// with its own clicks, sales and conversion rate. It records nothing unless
/// source, medium and campaign are all present.
public enum CheckoutLink {

    public enum Button: String, Sendable {
        case pro
        case drive
        /// "Add Google Drive previews" shown to Pro owners.
        case driveUpgrade = "drive-upgrade"
    }

    public static func url(plan: LicenseStore.Plan, button: Button,
                           access: LicenseStore.Access, week: UsageStats.Week) -> URL {
        let base = plan == .pro ? LicenseStore.buyProURL : LicenseStore.buyDriveURL
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "wanted", value: "true"),
            URLQueryItem(name: "utm_source", value: "spyglass-app"),
            URLQueryItem(name: "utm_medium", value: button.rawValue),
            URLQueryItem(name: "utm_campaign", value: campaign(access)),
            URLQueryItem(name: "utm_content", value: week.topCategory ?? "none"),
            URLQueryItem(name: "utm_term", value: bucket(week.total)),
        ]
        return parts.url!
    }

    static func campaign(_ access: LicenseStore.Access) -> String {
        switch access {
        case .trial(let days) where days >= 5: return "trial-early"
        case .trial:                           return "trial-late"
        case .pro, .proAndDrive:               return "pro"
        case .expired, .notStarted:            return "expired"
        }
    }

    /// Coarse on purpose: a handful of Gumroad link rows, and nothing close
    /// to a per-user fingerprint.
    static func bucket(_ total: Int) -> String {
        switch total {
        case ..<1:    return "0"
        case 1..<10:  return "1-9"
        case 10..<50: return "10-49"
        case 50..<200: return "50-199"
        default:      return "200+"
        }
    }
}
