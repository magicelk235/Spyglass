import XCTest
@testable import SpyglassKit

final class LicenseStoreTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var suites: [String] = []
    private func store() -> LicenseStore {
        let name = "spyglass-license-test-\(UUID().uuidString)"
        suites.append(name)
        return LicenseStore(defaults: UserDefaults(suiteName: name))
    }
    override func tearDown() {
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
    }

    // MARK: - Access

    func testTrialRunsSevenDaysThenExpires() {
        let start = now
        XCTAssertEqual(LicenseStore.access(plan: nil, membershipActive: false, trialStart: start, now: start), .trial(daysLeft: 7))
        XCTAssertEqual(LicenseStore.access(plan: nil, membershipActive: false, trialStart: start, now: start + 6.5 * day), .trial(daysLeft: 1))
        XCTAssertEqual(LicenseStore.access(plan: nil, membershipActive: false, trialStart: start, now: start + 7 * day), .expired)
        XCTAssertEqual(LicenseStore.access(plan: nil, membershipActive: false, trialStart: nil, now: now), .notStarted)
    }

    /// A clock set backwards must not extend the trial past its length.
    func testTrialStartInTheFutureCountsAsFullTrialOnly() {
        XCTAssertEqual(LicenseStore.access(plan: nil, membershipActive: false, trialStart: now + 30 * day, now: now), .trial(daysLeft: 7))
    }

    func testPlansGrantAccess() {
        let expiredTrial = now - 30 * day
        XCTAssertEqual(LicenseStore.access(plan: .pro, membershipActive: false, trialStart: expiredTrial, now: now), .pro)
        XCTAssertEqual(LicenseStore.access(plan: .legacy, membershipActive: false, trialStart: expiredTrial, now: now), .proAndDrive)
        XCTAssertEqual(LicenseStore.access(plan: .drive, membershipActive: true, trialStart: expiredTrial, now: now), .proAndDrive)
    }

    /// A lapsed membership drops back to whatever the trial allows.
    func testLapsedMembershipFallsBackToTrialState() {
        XCTAssertEqual(LicenseStore.access(plan: .drive, membershipActive: false, trialStart: now - 30 * day, now: now), .expired)
        XCTAssertEqual(LicenseStore.access(plan: .drive, membershipActive: false, trialStart: now, now: now), .trial(daysLeft: 7))
    }

    func testWhatEachAccessAllows() {
        XCTAssertTrue(LicenseStore.Access.trial(daysLeft: 3).allowsFormats)
        XCTAssertFalse(LicenseStore.Access.trial(daysLeft: 3).allowsDrive)
        XCTAssertTrue(LicenseStore.Access.pro.allowsFormats)
        XCTAssertFalse(LicenseStore.Access.pro.allowsDrive)
        XCTAssertTrue(LicenseStore.Access.proAndDrive.allowsDrive)
        XCTAssertFalse(LicenseStore.Access.expired.allowsFormats)
        XCTAssertFalse(LicenseStore.Access.notStarted.allowsFormats)
    }

    // MARK: - Stored state

    func testTrialStartsOnceAndIsNeverMovedLater() {
        let s = store()
        s.startTrialIfNeeded(now: now)
        s.startTrialIfNeeded(now: now + 3 * day)
        XCTAssertEqual(s.access(now: now + 3 * day), .trial(daysLeft: 4))
    }

    /// 1.0 stored only a key and `isPro`; that key belongs to the old product.
    func testOneOhLicenseReadsAsLegacyPlan() {
        let s = store()
        s.defaults?.set("KEY", forKey: "licenseKey")
        s.defaults?.set(true, forKey: "isPro")
        XCTAssertEqual(s.plan, .legacy)
        XCTAssertEqual(s.access(now: now), .proAndDrive)
    }

    func testClearRemovesTheLicenseButKeepsTheTrialClock() {
        let s = store()
        s.startTrialIfNeeded(now: now - 30 * day)
        s.save(.init(plan: .pro, key: "K", membershipActive: false), now: now)
        XCTAssertEqual(s.access(now: now), .pro)
        s.clear()
        XCTAssertNil(s.licenseKey)
        XCTAssertEqual(s.access(now: now), .expired)
    }

    // MARK: - Gumroad verdicts

    func testValidLiveSalePasses() throws {
        XCTAssertEqual(try LicenseStore.verdict(status: 200, body: data(#"{"success":true,"purchase":{"refunded":false}}"#), now: now),
                       .valid(membershipActive: true))
    }

    func testValidSaleWithNoPurchaseBlockPasses() throws {
        XCTAssertEqual(try LicenseStore.verdict(status: 200, body: data(#"{"success":true}"#), now: now), .valid(membershipActive: true))
    }

    func testUnknownKeyThrowsInvalid() {
        XCTAssertThrowsError(try LicenseStore.verdict(status: 404, body: data(#"{"success":false}"#), now: now)) {
            XCTAssertEqual($0 as? LicenseStore.LicenseError, .invalidKey)
        }
    }

    func testRefundedThrowsRefunded() {
        XCTAssertThrowsError(try LicenseStore.verdict(status: 200, body: data(#"{"success":true,"purchase":{"refunded":true}}"#), now: now)) {
            XCTAssertEqual($0 as? LicenseStore.LicenseError, .refunded)
        }
    }

    func testChargebackedThrowsRefunded() {
        XCTAssertThrowsError(try LicenseStore.verdict(status: 200, body: data(#"{"success":true,"purchase":{"chargebacked":true}}"#), now: now)) {
            XCTAssertEqual($0 as? LicenseStore.LicenseError, .refunded)
        }
    }

    func testGarbageBodyThrowsMalformed() {
        XCTAssertThrowsError(try LicenseStore.verdict(status: 200, body: data("not json"), now: now)) {
            XCTAssertEqual($0 as? LicenseStore.LicenseError, .malformed)
        }
    }

    func testEndedOrFailedSubscriptionIsInactive() throws {
        for field in ["subscription_ended_at", "subscription_failed_at"] {
            let body = #"{"success":true,"purchase":{"\#(field)":"2026-01-01T00:00:00Z"}}"#
            XCTAssertEqual(try LicenseStore.verdict(status: 200, body: data(body), now: now), .valid(membershipActive: false), field)
        }
    }

    /// Cancelling keeps access until the paid period is over.
    func testCancelledSubscriptionStaysActiveUntilTheCancellationDate() throws {
        let future = ISO8601DateFormatter().string(from: now + 10 * day)
        let past = ISO8601DateFormatter().string(from: now - day)
        XCTAssertEqual(try LicenseStore.verdict(status: 200, body: data(#"{"success":true,"purchase":{"subscription_cancelled_at":"\#(future)"}}"#), now: now),
                       .valid(membershipActive: true))
        XCTAssertEqual(try LicenseStore.verdict(status: 200, body: data(#"{"success":true,"purchase":{"subscription_cancelled_at":"\#(past)"}}"#), now: now),
                       .valid(membershipActive: false))
    }

    func testFormEncodesProductIDReservedChars() {
        let encoded = LicenseStore.form("YMTEmgQNPRDS27c2B_bflw==")
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
    }

    // MARK: - Activation across products

    /// A key is tried against each product until one recognizes it.
    func testActivationFindsTheProductThatOwnsTheKey() async throws {
        let s = store()
        let plan = try await s.activate(key: " K-1 \n", now: now) { product, key in
            XCTAssertEqual(key, "K-1")
            return product == .pro ? .valid(membershipActive: true) : nil
        }
        XCTAssertEqual(plan, .pro)
        XCTAssertEqual(s.licenseKey, "K-1")
        XCTAssertEqual(s.access(now: now + 365 * day), .pro)
    }

    func testActivationWithAnUnknownKeyChangesNothing() async {
        let s = store()
        s.save(.init(plan: .pro, key: "OLD", membershipActive: false), now: now)
        do {
            _ = try await s.activate(key: "NOPE", now: now) { _, _ in nil }
            XCTFail("expected invalidKey")
        } catch {
            XCTAssertEqual(error as? LicenseStore.LicenseError, .invalidKey)
        }
        XCTAssertEqual(s.licenseKey, "OLD")
    }

    func testRecheckUpdatesMembershipAndDropsRefundedKeys() async throws {
        let s = store()
        s.save(.init(plan: .drive, key: "K", membershipActive: true), now: now)
        try await s.recheck(now: now) { _, _ in .valid(membershipActive: false) }
        XCTAssertEqual(s.access(now: now), .notStarted)

        s.save(.init(plan: .pro, key: "K", membershipActive: false), now: now)
        try await s.recheck(now: now) { _, _ in throw LicenseStore.LicenseError.refunded }
        XCTAssertNil(s.licenseKey)
    }

    /// Being offline must never take away what was paid for.
    func testRecheckKeepsStateWhenGumroadIsUnreachable() async {
        let s = store()
        s.save(.init(plan: .drive, key: "K", membershipActive: true), now: now)
        try? await s.recheck(now: now) { _, _ in throw LicenseStore.LicenseError.network(503) }
        XCTAssertEqual(s.access(now: now), .proAndDrive)
    }
}
