import Foundation

/// What the user has paid for, and the free trial clock.
///
/// The app writes everything here (trial start, verified key, plan); the Quick
/// Look and thumbnail extensions only read it, through `access(now:)`. It all
/// lives in the shared App Group defaults so every process sees the same state.
///
/// Plans:
/// - `pro`: one-time purchase, every format preview.
/// - `drive`: monthly membership, format previews plus rendered Google
///   Drive previews while the subscription is active.
/// - `legacy`: a Spyglass 1.0 key; those buyers keep Drive previews for life.
///
/// New keys are sold on Polar, one license-key benefit per plan. Keys sold
/// earlier on Gumroad (one product per plan, plus 1.0) keep working and are
/// still checked with Gumroad.
public struct LicenseStore {

    public enum Plan: String, CaseIterable, Sendable {
        case drive, pro, legacy

        /// The Gumroad product that sold this plan's older keys.
        public var productID: String {
            switch self {
            case .pro:    return "FwpNXeTGeL3EaXXcPQo0Fg=="
            case .drive:  return "t6Yyd5RKHTKEQn3tUHYtvg=="
            case .legacy: return "YMTEmgQNPRDS27c2B_bflw=="
            }
        }

        /// The Polar license-key benefit for this plan. 1.0 was never sold on Polar.
        public var polarBenefitID: String? {
            switch self {
            case .pro:    return "87a7e00e-fbc4-4419-861d-f9013406a6f7"
            case .drive:  return "ba0435a3-c11c-4581-8f4b-78689062dd88"
            case .legacy: return nil
            }
        }

        /// nil for a benefit from another product on the same Polar account.
        public static func forPolarBenefit(_ id: String) -> Plan? {
            allCases.first { $0.polarBenefitID == id }
        }
    }

    /// Where the stored key was bought, and so who confirms it.
    public enum Issuer: String, Sendable {
        case polar, gumroad
    }

    public enum Access: Equatable, Sendable {
        /// The app has never been opened, so the trial clock hasn't started.
        case notStarted
        case trial(daysLeft: Int)
        case expired
        case pro
        case proAndDrive

        public var allowsFormats: Bool {
            switch self {
            case .trial, .pro, .proAndDrive: return true
            case .notStarted, .expired:      return false
            }
        }

        public var allowsDrive: Bool { self == .proAndDrive }
    }

    public static let trialDays = 7

    public static let buyProURL = URL(string: "https://magicelk235.gumroad.com/l/spyglass")!
    public static let buyDriveURL = URL(string: "https://magicelk235.gumroad.com/l/spyglass-drive")!

    /// Not a secret: Polar's customer-portal license endpoints only need it to
    /// know which seller's keys to look in.
    public static let polarOrganizationID = "760e4bf4-f5a2-4a74-8a22-66da54f6f33b"

    static let proKey = "isPro"
    static let keyKey = "licenseKey"
    static let planKey = "licensePlan"
    static let issuerKey = "licenseIssuer"
    static let membershipKey = "membershipActive"
    static let checkedKey = "licenseCheckedAt"
    static let trialKey = "trialStartedAt"

    let defaults: UserDefaults?

    public init(groupID: String = AppGroup.identifier) {
        defaults = UserDefaults(suiteName: groupID)
    }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    // MARK: - Reading

    public var licenseKey: String? { defaults?.string(forKey: Self.keyKey) }

    /// 1.0 stored only the key and an `isPro` flag; such a key can only belong
    /// to the 1.0 product.
    public var plan: Plan? {
        guard licenseKey != nil else { return nil }
        if let raw = defaults?.string(forKey: Self.planKey) { return Plan(rawValue: raw) }
        return defaults?.bool(forKey: Self.proKey) == true ? .legacy : nil
    }

    /// Keys stored before Polar have no issuer; they all came from Gumroad.
    public var issuer: Issuer? {
        guard licenseKey != nil else { return nil }
        return defaults?.string(forKey: Self.issuerKey).flatMap(Issuer.init(rawValue:)) ?? .gumroad
    }

    public var membershipActive: Bool { defaults?.bool(forKey: Self.membershipKey) ?? false }
    public var lastChecked: Date? { defaults?.object(forKey: Self.checkedKey) as? Date }
    public var trialStart: Date? { defaults?.object(forKey: Self.trialKey) as? Date }

    public func access(now: Date = Date()) -> Access {
        Self.access(plan: plan, membershipActive: membershipActive, trialStart: trialStart, now: now)
    }

    public static func access(plan: Plan?, membershipActive: Bool, trialStart: Date?, now: Date) -> Access {
        switch plan {
        case .legacy:                      return .proAndDrive
        case .drive where membershipActive: return .proAndDrive
        case .pro:                         return .pro
        case .drive, nil:                  break
        }
        guard let trialStart else { return .notStarted }
        // A start date in the future (clock moved back) still only buys one trial.
        let elapsed = max(0, now.timeIntervalSince(trialStart))
        let left = Double(trialDays) * 86_400 - elapsed
        guard left > 0 else { return .expired }
        return .trial(daysLeft: Int((left / 86_400).rounded(.up)))
    }

    // MARK: - Writing (app only)

    /// Starts the free week the first time the app runs; never moves it.
    public func startTrialIfNeeded(now: Date = Date()) {
        guard trialStart == nil else { return }
        defaults?.set(now, forKey: Self.trialKey)
    }

    struct Saved {
        var plan: Plan
        var key: String
        var membershipActive: Bool
        var issuer: Issuer
    }

    func save(_ saved: Saved, now: Date) {
        defaults?.set(saved.key, forKey: Self.keyKey)
        defaults?.set(saved.plan.rawValue, forKey: Self.planKey)
        defaults?.set(saved.issuer.rawValue, forKey: Self.issuerKey)
        defaults?.set(saved.membershipActive, forKey: Self.membershipKey)
        defaults?.set(now, forKey: Self.checkedKey)
        defaults?.removeObject(forKey: Self.proKey)
    }

    /// Removes the license (the user deactivates, or the store reports a refund).
    /// The trial clock stays: deactivating never restarts the free week.
    public func clear() {
        for key in [Self.proKey, Self.keyKey, Self.planKey, Self.issuerKey, Self.membershipKey, Self.checkedKey] {
            defaults?.removeObject(forKey: key)
        }
    }

    // MARK: - Checking keys

    public enum LicenseError: Error, LocalizedError, Equatable {
        case invalidKey
        case refunded
        /// A Polar key for another app on the same account (Lector, Viaduct).
        case otherProduct
        case network(Int)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .invalidKey:     return "License key not recognized."
            case .refunded:       return "This purchase was refunded or disputed."
            case .otherProduct:   return "This key is for another Magicelklabs app."
            case .network(let c): return c == 0 ? "Couldn't reach the license server." : "Couldn't reach the license server (HTTP \(c))."
            case .malformed:      return "Unexpected response from the license server."
            }
        }
    }

    public enum Verdict: Equatable, Sendable {
        /// `membershipActive` is meaningful only for the Drive membership; a
        /// one-time purchase reports true.
        case valid(membershipActive: Bool)
    }

    /// Asks Gumroad about a key for one product. nil means that product
    /// doesn't know the key.
    public typealias Verifier = @Sendable (Plan, String) async throws -> Verdict?

    public enum PolarAnswer: Equatable, Sendable {
        /// The key is live and was sold under this benefit.
        case granted(benefitID: String)
        /// Polar never issued the key, so it may be from Gumroad.
        case unknown
        /// Polar issued the key, but it is revoked, disabled or expired: a
        /// refund, or a subscription that ended.
        case refused
    }

    /// Asks Polar about a key. Throws when Polar can't give an answer.
    public typealias PolarVerifier = @Sendable (String) async throws -> PolarAnswer

    /// Asks Polar first. Only a key Polar has never heard of is tried against
    /// each Gumroad product; an outage stops here, so a Polar key is never
    /// misreported as unknown. Leaves any stored license untouched on failure.
    @discardableResult
    public func activate(key: String, now: Date = Date(),
                         polar: PolarVerifier = LicenseStore.polar,
                         gumroad: Verifier = LicenseStore.gumroad) async throws -> Plan {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        switch try await polar(trimmed) {
        case .granted(let benefit):
            guard let plan = Plan.forPolarBenefit(benefit) else { throw LicenseError.otherProduct }
            save(Saved(plan: plan, key: trimmed, membershipActive: true, issuer: .polar), now: now)
            return plan
        case .refused:
            throw LicenseError.invalidKey
        case .unknown:
            break
        }
        for plan in Plan.allCases {
            if case .valid(let active)? = try await gumroad(plan, trimmed) {
                save(Saved(plan: plan, key: trimmed, membershipActive: active, issuer: .gumroad), now: now)
                return plan
            }
        }
        throw LicenseError.invalidKey
    }

    /// Re-asks the store that sold the key: picks up a lapsed or renewed
    /// membership and drops refunded keys. A network failure throws and changes
    /// nothing, so being offline never removes paid access.
    public func recheck(now: Date = Date(),
                        polar: PolarVerifier = LicenseStore.polar,
                        gumroad: Verifier = LicenseStore.gumroad) async throws {
        guard let key = licenseKey, let plan, let issuer else { return }
        switch issuer {
        case .polar:
            if case .granted(let benefit) = try await polar(key), benefit == plan.polarBenefitID {
                save(Saved(plan: plan, key: key, membershipActive: true, issuer: .polar), now: now)
            } else if plan == .drive {
                // Kept, so a renewed subscription comes back on the next check
                // and Settings can say the membership ended.
                save(Saved(plan: plan, key: key, membershipActive: false, issuer: .polar), now: now)
            } else {
                clear()
            }
        case .gumroad:
            do {
                guard case .valid(let active)? = try await gumroad(plan, key) else {
                    clear()
                    return
                }
                save(Saved(plan: plan, key: key, membershipActive: active, issuer: .gumroad), now: now)
            } catch LicenseError.refunded, LicenseError.invalidKey {
                clear()
            }
        }
    }

    /// The live Polar verifier: the customer-portal endpoint, which needs no
    /// access token. No Polar-Version header: Polar retires a pinned version
    /// after about nine months and then answers 404 to everything.
    public static let polar: PolarVerifier = { key in
        var req = URLRequest(url: URL(string: "https://api.polar.sh/v1/customer-portal/license-keys/validate")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["key": key, "organization_id": polarOrganizationID])
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw LicenseError.network(0)
        }
        return try polarAnswer(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    /// Pure decision from Polar's response, split out for tests. Only Polar's
    /// own error bodies count as a no; an outage or a proxy's page keeps the key.
    static func polarAnswer(status: Int, body: Data) throws -> PolarAnswer {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if status == 200 {
            guard let benefit = json?["benefit_id"] as? String else { throw LicenseError.malformed }
            return .granted(benefitID: benefit)
        }
        guard status == 404, json?["error"] as? String == "ResourceNotFound",
              let detail = json?["detail"] as? String else {
            throw LicenseError.network(status)
        }
        // Polar's stock detail for a key it doesn't have at all.
        return detail == "Not found" ? .unknown : .refused
    }

    /// The live Gumroad verifier, for keys bought there before Polar.
    public static let gumroad: Verifier = { plan, key in
        var req = URLRequest(url: URL(string: "https://api.gumroad.com/v2/licenses/verify")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // increment_uses_count=false so re-verifying on every launch doesn't
        // inflate the seat count and trip Gumroad's per-key usage cap.
        req.httpBody = Data(("product_id=\(form(plan.productID))"
            + "&license_key=\(form(key))&increment_uses_count=false").utf8)
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw LicenseError.network(0)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // Gumroad answers 404 {"success":false} for a key it doesn't know.
        if code == 404 { return nil }
        guard code == 200 else { throw LicenseError.network(code) }
        return try verdict(status: code, body: data, now: Date())
    }

    /// Pure decision from Gumroad's response, split out for tests.
    static func verdict(status: Int, body: Data, now: Date) throws -> Verdict {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw LicenseError.malformed
        }
        guard (json["success"] as? Bool) == true else { throw LicenseError.invalidKey }
        guard let purchase = json["purchase"] as? [String: Any] else { return .valid(membershipActive: true) }

        // success=true only means the key exists, not that the sale still stands.
        if ["refunded", "disputed", "chargebacked"].contains(where: { (purchase[$0] as? Bool) == true }) {
            throw LicenseError.refunded
        }
        func date(_ field: String) -> Date? {
            (purchase[field] as? String).flatMap { ISO8601DateFormatter().date(from: $0) ?? Date.distantPast }
        }
        if date("subscription_ended_at") != nil || date("subscription_failed_at") != nil {
            return .valid(membershipActive: false)
        }
        // Cancelling keeps access until the end of the period already paid for.
        if let cancelled = date("subscription_cancelled_at"), cancelled <= now {
            return .valid(membershipActive: false)
        }
        return .valid(membershipActive: true)
    }

    static func form(_ s: String) -> String {
        // Product ids contain '=' and '+'; percent-encode for the form body.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
