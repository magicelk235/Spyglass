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
        s.save(.init(plan: .pro, key: "K", membershipActive: false, issuer: .gumroad), now: now)
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

    // MARK: - Polar answers

    func testPolarGrantedBodyGivesItsBenefit() throws {
        XCTAssertEqual(try LicenseStore.polarAnswer(status: 200, body: data(#"{"benefit_id":"B","status":"granted"}"#)),
                       .granted(benefitID: "B"))
    }

    /// Polar's stock "Not found" means it never issued the key, so it may be a Gumroad key.
    func testPolarStockNotFoundIsUnknown() throws {
        XCTAssertEqual(try LicenseStore.polarAnswer(status: 404, body: data(#"{"error":"ResourceNotFound","detail":"Not found"}"#)),
                       .unknown)
    }

    func testPolarOtherNotFoundDetailIsRefused() throws {
        XCTAssertEqual(try LicenseStore.polarAnswer(status: 404, body: data(#"{"error":"ResourceNotFound","detail":"License key is revoked"}"#)),
                       .refused)
    }

    /// Only Polar's own error bodies count as an answer; anything else is an outage.
    func testNonPolarResponsesThrowNetworkOrMalformed() {
        XCTAssertThrowsError(try LicenseStore.polarAnswer(status: 502, body: data("<html>Bad gateway</html>"))) {
            XCTAssertEqual($0 as? LicenseStore.LicenseError, .network(502))
        }
        XCTAssertThrowsError(try LicenseStore.polarAnswer(status: 404, body: data("<html>Not found</html>"))) {
            XCTAssertEqual($0 as? LicenseStore.LicenseError, .network(404))
        }
        XCTAssertThrowsError(try LicenseStore.polarAnswer(status: 200, body: data(#"{"status":"granted"}"#))) {
            XCTAssertEqual($0 as? LicenseStore.LicenseError, .malformed)
        }
    }

    func testPlanForPolarBenefit() {
        XCTAssertEqual(LicenseStore.Plan.forPolarBenefit("87a7e00e-fbc4-4419-861d-f9013406a6f7"), .pro)
        XCTAssertEqual(LicenseStore.Plan.forPolarBenefit("ba0435a3-c11c-4581-8f4b-78689062dd88"), .drive)
        XCTAssertNil(LicenseStore.Plan.forPolarBenefit("fba4c928-be07-45ea-989a-70d343713df5"))
        XCTAssertNil(LicenseStore.Plan.legacy.polarBenefitID)
    }

    // MARK: - Activation

    private let proBenefit = LicenseStore.Plan.pro.polarBenefitID!
    private let driveBenefit = LicenseStore.Plan.drive.polarBenefitID!
    private let noGumroad: LicenseStore.Verifier = { _, _ in XCTFail("Gumroad must not be asked"); return nil }
    private let noPolar: LicenseStore.PolarVerifier = { _ in XCTFail("Polar must not be asked"); return .unknown }

    func testActivateWithPolarProKeyStoresPolarPro() async throws {
        let s = store()
        let benefit = proBenefit
        let plan = try await s.activate(key: " P-1 \n", now: now, polar: { key in
            XCTAssertEqual(key, "P-1")
            return .granted(benefitID: benefit)
        }, gumroad: noGumroad)
        XCTAssertEqual(plan, .pro)
        XCTAssertEqual(s.licenseKey, "P-1")
        XCTAssertEqual(s.issuer, .polar)
        XCTAssertEqual(s.access(now: now + 365 * day), .pro)
    }

    func testActivateWithPolarDriveKeyGivesProAndDrive() async throws {
        let s = store()
        let benefit = driveBenefit
        try await s.activate(key: "D-1", now: now, polar: { _ in .granted(benefitID: benefit) }, gumroad: noGumroad)
        XCTAssertEqual(s.plan, .drive)
        XCTAssertEqual(s.access(now: now), .proAndDrive)
    }

    /// A Lector or Viaduct key sold on the same Polar account.
    func testActivateRejectsAnotherProductsPolarKey() async {
        let s = store()
        s.save(.init(plan: .pro, key: "OLD", membershipActive: true, issuer: .polar), now: now)
        do {
            _ = try await s.activate(key: "LECTOR", now: now, polar: { _ in .granted(benefitID: "fba4c928-be07-45ea-989a-70d343713df5") },
                                     gumroad: noGumroad)
            XCTFail("expected otherProduct")
        } catch {
            XCTAssertEqual(error as? LicenseStore.LicenseError, .otherProduct)
        }
        XCTAssertEqual(s.licenseKey, "OLD")
    }

    /// A key Polar never issued is tried against each Gumroad product.
    func testActivateFallsBackToGumroadOnlyOnNotFound() async throws {
        let s = store()
        let plan = try await s.activate(key: " K-1 \n", now: now, polar: { _ in .unknown }) { product, key in
            XCTAssertEqual(key, "K-1")
            return product == .legacy ? .valid(membershipActive: true) : nil
        }
        XCTAssertEqual(plan, .legacy)
        XCTAssertEqual(s.licenseKey, "K-1")
        XCTAssertEqual(s.issuer, .gumroad)
        XCTAssertEqual(s.access(now: now + 365 * day), .proAndDrive)
    }

    func testActivateRefusedPolarKeyIsInvalid() async {
        let s = store()
        do {
            _ = try await s.activate(key: "REVOKED", now: now, polar: { _ in .refused }, gumroad: noGumroad)
            XCTFail("expected invalidKey")
        } catch {
            XCTAssertEqual(error as? LicenseStore.LicenseError, .invalidKey)
        }
        XCTAssertNil(s.licenseKey)
    }

    /// An outage must not be read as "not a Polar key" and sent to Gumroad.
    func testActivateDoesNotFallBackToGumroadWhenPolarIsUnreachable() async {
        let s = store()
        do {
            _ = try await s.activate(key: "P-1", now: now, polar: { _ in throw LicenseStore.LicenseError.network(0) }, gumroad: noGumroad)
            XCTFail("expected network")
        } catch {
            XCTAssertEqual(error as? LicenseStore.LicenseError, .network(0))
        }
        XCTAssertNil(s.licenseKey)
    }

    func testActivationWithAnUnknownKeyChangesNothing() async {
        let s = store()
        s.save(.init(plan: .pro, key: "OLD", membershipActive: false, issuer: .gumroad), now: now)
        do {
            _ = try await s.activate(key: "NOPE", now: now, polar: { _ in .unknown }) { _, _ in nil }
            XCTFail("expected invalidKey")
        } catch {
            XCTAssertEqual(error as? LicenseStore.LicenseError, .invalidKey)
        }
        XCTAssertEqual(s.licenseKey, "OLD")
    }

    // MARK: - Recheck

    func testRecheckUpdatesMembershipAndDropsRefundedKeys() async throws {
        let s = store()
        s.save(.init(plan: .drive, key: "K", membershipActive: true, issuer: .gumroad), now: now)
        try await s.recheck(now: now, polar: noPolar) { _, _ in .valid(membershipActive: false) }
        XCTAssertEqual(s.access(now: now), .notStarted)

        s.save(.init(plan: .pro, key: "K", membershipActive: false, issuer: .gumroad), now: now)
        try await s.recheck(now: now, polar: noPolar) { _, _ in throw LicenseStore.LicenseError.refunded }
        XCTAssertNil(s.licenseKey)
    }

    /// Being offline must never take away what was paid for.
    func testRecheckKeepsStateWhenGumroadIsUnreachable() async {
        let s = store()
        s.save(.init(plan: .drive, key: "K", membershipActive: true, issuer: .gumroad), now: now)
        try? await s.recheck(now: now, polar: noPolar) { _, _ in throw LicenseStore.LicenseError.network(503) }
        XCTAssertEqual(s.access(now: now), .proAndDrive)
    }

    /// Installs from before Polar stored no issuer; their keys came from Gumroad.
    func testStoredKeyWithoutIssuerRechecksWithGumroad() async throws {
        let s = store()
        s.defaults?.set("K", forKey: "licenseKey")
        s.defaults?.set("pro", forKey: "licensePlan")
        XCTAssertEqual(s.issuer, .gumroad)
        // Gumroad reporting a refund clears the key; Polar would fail the test if asked.
        try await s.recheck(now: now, polar: noPolar) { plan, key in
            XCTAssertEqual(plan, .pro)
            XCTAssertEqual(key, "K")
            throw LicenseStore.LicenseError.refunded
        }
        XCTAssertNil(s.licenseKey)
    }

    /// A lapsed Polar subscription keeps the key so a renewal comes back by itself.
    func testRecheckKeepsLapsedPolarDriveKeyAndRestoresIt() async throws {
        let s = store()
        let benefit = driveBenefit
        s.save(.init(plan: .drive, key: "D", membershipActive: true, issuer: .polar), now: now)
        try await s.recheck(now: now, polar: { _ in .refused }, gumroad: noGumroad)
        XCTAssertEqual(s.licenseKey, "D")
        XCTAssertEqual(s.plan, .drive)
        XCTAssertEqual(s.access(now: now), .notStarted)

        try await s.recheck(now: now, polar: { _ in .granted(benefitID: benefit) }, gumroad: noGumroad)
        XCTAssertEqual(s.access(now: now), .proAndDrive)
    }

    func testRecheckClearsRefusedPolarProKey() async throws {
        let s = store()
        s.save(.init(plan: .pro, key: "P", membershipActive: true, issuer: .polar), now: now)
        try await s.recheck(now: now, polar: { _ in .refused }, gumroad: noGumroad)
        XCTAssertNil(s.licenseKey)
    }

    /// No silent plan change: a stored Pro key now reporting Drive's benefit is a no for Pro.
    func testRecheckTreatsDifferentBenefitAsNo() async throws {
        let s = store()
        let benefit = driveBenefit
        s.save(.init(plan: .pro, key: "P", membershipActive: true, issuer: .polar), now: now)
        try await s.recheck(now: now, polar: { _ in .granted(benefitID: benefit) }, gumroad: noGumroad)
        XCTAssertNil(s.licenseKey)
    }

    func testRecheckKeepsPolarStateWhenUnreachable() async {
        let s = store()
        s.save(.init(plan: .drive, key: "D", membershipActive: true, issuer: .polar), now: now)
        try? await s.recheck(now: now, polar: { _ in throw LicenseStore.LicenseError.network(503) }, gumroad: noGumroad)
        XCTAssertEqual(s.access(now: now), .proAndDrive)
    }

    func testClearRemovesIssuer() {
        let s = store()
        s.save(.init(plan: .pro, key: "P", membershipActive: true, issuer: .polar), now: now)
        s.clear()
        XCTAssertNil(s.issuer)
    }
}
