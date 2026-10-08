import Foundation

/// What the user has paid for, and the free trial clock.
///
/// The app writes everything here (trial start, verified key, plan); the Quick
/// Look and thumbnail extensions only read it, through `access(now:)`. It all
/// lives in the shared App Group defaults so every process sees the same state.
///
/// Plans, one Gumroad product each:
/// - `pro`: one-time purchase, every format preview.
/// - `drive`: monthly/yearly membership, format previews plus rendered Google
///   Drive previews while the subscription is active.
/// - `legacy`: a Spyglass 1.0 key; those buyers keep Drive previews for life.
public struct LicenseStore {

    public enum Plan: String, CaseIterable, Sendable {
        case drive, pro, legacy

        public var productID: String {
            switch self {
            case .pro:    return "FwpNXeTGeL3EaXXcPQo0Fg=="
            case .drive:  return "t6Yyd5RKHTKEQn3tUHYtvg=="
            case .legacy: return "YMTEmgQNPRDS27c2B_bflw=="
            }
        }
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

    public static let buyProURL = URL(string: "https://magicelk235.gumroad.com/l/spyglass-pro")!
    public static let buyDriveURL = URL(string: "https://magicelk235.gumroad.com/l/spyglass-drive")!

    static let proKey = "isPro"
    static let keyKey = "licenseKey"
    static let planKey = "licensePlan"
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
    }

    func save(_ saved: Saved, now: Date) {
        defaults?.set(saved.key, forKey: Self.keyKey)
        defaults?.set(saved.plan.rawValue, forKey: Self.planKey)
        defaults?.set(saved.membershipActive, forKey: Self.membershipKey)
        defaults?.set(now, forKey: Self.checkedKey)
        defaults?.removeObject(forKey: Self.proKey)
    }

    /// Removes the license (the user deactivates, or Gumroad reports a refund).
    /// The trial clock stays: deactivating never restarts the free week.
    public func clear() {
        for key in [Self.proKey, Self.keyKey, Self.planKey, Self.membershipKey, Self.checkedKey] {
            defaults?.removeObject(forKey: key)
        }
    }

    // MARK: - Gumroad

    public enum LicenseError: Error, LocalizedError, Equatable {
        case invalidKey
        case refunded
        case network(Int)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .invalidKey:     return "License key not recognized."
            case .refunded:       return "This purchase was refunded or disputed."
            case .network(let c): return c == 0 ? "Couldn't reach Gumroad." : "Couldn't reach Gumroad (HTTP \(c))."
            case .malformed:      return "Unexpected response from Gumroad."
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

    /// Tries the key against each product until one recognizes it, then
    /// stores it. Throws `invalidKey` when no product does; leaves any stored
    /// license untouched on failure.
    @discardableResult
    public func activate(key: String, now: Date = Date(),
                         verify: Verifier = LicenseStore.gumroad) async throws -> Plan {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        for plan in Plan.allCases {
            if case .valid(let active)? = try await verify(plan, trimmed) {
                save(Saved(plan: plan, key: trimmed, membershipActive: active), now: now)
                return plan
            }
        }
        throw LicenseError.invalidKey
    }

    /// Re-asks Gumroad about the stored key: picks up a lapsed or renewed
    /// membership and drops refunded keys. A network failure throws and changes
    /// nothing, so being offline never removes paid access.
    public func recheck(now: Date = Date(), verify: Verifier = LicenseStore.gumroad) async throws {
        guard let key = licenseKey, let plan else { return }
        do {
            guard case .valid(let active)? = try await verify(plan, key) else {
                clear()
                return
            }
            save(Saved(plan: plan, key: key, membershipActive: active), now: now)
        } catch LicenseError.refunded, LicenseError.invalidKey {
            clear()
        }
    }

    /// The live verifier: Gumroad's license API.
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
