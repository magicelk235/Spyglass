import XCTest
@testable import SpyglassKit

final class UsageStatsTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// Noon, so whole-day offsets never straddle midnight.
    private let now = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86_400) + 43_200)

    private var dirs: [URL] = []
    private func stats() -> UsageStats {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spyglass-usage-\(UUID().uuidString)")
        dirs.append(dir)
        return UsageStats(fileURL: dir.appendingPathComponent("Spyglass/usage.json"), calendar: calendar)
    }
    override func tearDown() {
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    func testCountsTheLastSevenDaysOnly() {
        let s = stats()
        s.record(.markdown, now: now - 7 * day)   // eight days ago counting today: outside
        s.record(.markdown, now: now - 6 * day)
        s.record(.code, now: now)
        s.record(.code, now: now)
        let week = s.week(now: now)
        XCTAssertEqual(week.total, 3)
        XCTAssertEqual(week.count(.markdown), 1)
        XCTAssertEqual(week.count(.code), 2)
    }

    func testOldDaysArePrunedWhenRecording() {
        let s = stats()
        s.record(.markdown, now: now - 30 * day)
        s.record(.markdown, now: now)
        XCTAssertEqual(s.storedDays, 1)
    }

    func testDriveIsCountedSeparatelyFromFormats() {
        let s = stats()
        s.recordDrive(now: now)
        s.recordDrive(now: now)
        s.record(.notebook, now: now)
        let week = s.week(now: now)
        XCTAssertEqual(week.drive, 2)
        XCTAssertEqual(week.total, 3)
        XCTAssertEqual(week.topFormats(3).map(\.group), [.notebook])
    }

    func testTopFormatsAreOrderedByCountThenName() {
        let s = stats()
        for _ in 0..<3 { s.record(.code, now: now) }
        for _ in 0..<5 { s.record(.markdown, now: now) }
        s.record(.diff, now: now)
        s.record(.archive, now: now)
        let top = s.week(now: now).topFormats(3)
        XCTAssertEqual(top.map(\.group), [.markdown, .code, .archive])
        XCTAssertEqual(top.map(\.count), [5, 3, 1])
    }

    func testCorruptStoredValueIsIgnored() {
        let s = stats()
        try? FileManager.default.createDirectory(at: s.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("garbage".utf8).write(to: s.fileURL)
        XCTAssertEqual(s.week(now: now).total, 0)
        s.record(.code, now: now)
        XCTAssertEqual(s.week(now: now).total, 1)
    }

    // MARK: - Summary line

    func testSummaryLine() {
        let s = stats()
        XCTAssertNil(s.week(now: now).summary)
        s.record(.markdown, now: now)
        XCTAssertEqual(s.week(now: now).summary, "This week: 1 preview. Markdown 1.")
        for _ in 0..<2 { s.record(.code, now: now) }
        s.record(.notebook, now: now)
        s.record(.folder, now: now)
        XCTAssertEqual(s.week(now: now).summary, "This week: 5 previews. Code 2, Folders 1, Markdown 1.")
    }

    // MARK: - Checkout link

    func testUsageBuckets() {
        XCTAssertEqual(CheckoutLink.bucket(0), "0")
        XCTAssertEqual(CheckoutLink.bucket(1), "1-9")
        XCTAssertEqual(CheckoutLink.bucket(9), "1-9")
        XCTAssertEqual(CheckoutLink.bucket(10), "10-49")
        XCTAssertEqual(CheckoutLink.bucket(49), "10-49")
        XCTAssertEqual(CheckoutLink.bucket(50), "50-199")
        XCTAssertEqual(CheckoutLink.bucket(199), "50-199")
        XCTAssertEqual(CheckoutLink.bucket(200), "200+")
    }

    func testCampaignFollowsTheTrial() {
        XCTAssertEqual(CheckoutLink.campaign(.trial(daysLeft: 7)), "trial-early")
        XCTAssertEqual(CheckoutLink.campaign(.trial(daysLeft: 5)), "trial-early")
        XCTAssertEqual(CheckoutLink.campaign(.trial(daysLeft: 4)), "trial-late")
        XCTAssertEqual(CheckoutLink.campaign(.trial(daysLeft: 1)), "trial-late")
        XCTAssertEqual(CheckoutLink.campaign(.expired), "expired")
        XCTAssertEqual(CheckoutLink.campaign(.notStarted), "expired")
        XCTAssertEqual(CheckoutLink.campaign(.pro), "pro")
    }

    /// The link must carry all three of source, medium and campaign, or
    /// Gumroad doesn't record the visit; and go straight to checkout.
    func testLinkCarriesCheckoutAndAllTags() throws {
        let s = stats()
        for _ in 0..<12 { s.record(.markdown, now: now) }
        s.record(.code, now: now)
        let url = CheckoutLink.url(plan: .pro, button: .pro, access: .trial(daysLeft: 2), week: s.week(now: now))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "magicelk235.gumroad.com")
        XCTAssertEqual(parts.path, "/l/spyglass")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, [
            "wanted": "true",
            "utm_source": "spyglass-app",
            "utm_medium": "pro",
            "utm_campaign": "trial-late",
            "utm_content": "markdown",
            "utm_term": "10-49",
        ])
    }

    func testLinkWithNoUsageAndDriveAsTopCategory() throws {
        let empty = CheckoutLink.url(plan: .drive, button: .driveUpgrade, access: .pro, week: stats().week(now: now))
        XCTAssertTrue(empty.absoluteString.contains("utm_content=none"))
        XCTAssertTrue(empty.absoluteString.contains("utm_medium=drive-upgrade"))
        XCTAssertTrue(empty.absoluteString.hasPrefix("https://magicelk235.gumroad.com/l/spyglass-drive?"))

        let s = stats()
        for _ in 0..<3 { s.recordDrive(now: now) }
        s.record(.code, now: now)
        let url = CheckoutLink.url(plan: .drive, button: .drive, access: .expired, week: s.week(now: now))
        XCTAssertTrue(url.absoluteString.contains("utm_content=drive"))
        XCTAssertTrue(url.absoluteString.contains("utm_term=1-9"))
    }
}
