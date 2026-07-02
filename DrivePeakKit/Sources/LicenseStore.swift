import Foundation

/// Gumroad license gate for the paid Tier 1 (rendered previews).
///
/// The app verifies a license key against Gumroad and, on success, writes a
/// `pro` flag into the shared App Group defaults. FetchWorker reads that flag
/// before fetching PDF exports — no license, no fetch, so the extension keeps
/// showing the free Tier 0 card. The flag lives in the SAME shared suite the
/// fetch-request channel uses, so both processes see it.
public struct LicenseStore {
    // Gumroad product for DrivePeak Tier 1.
    public static let productID = "YMTEmgQNPRDS27c2B_bflw=="

    private static let proKey = "isPro"
    private static let keyKey = "licenseKey"

    private let defaults: UserDefaults?

    public init(groupID: String = "group.com.drivepeak.shared") {
        defaults = UserDefaults(suiteName: groupID)
    }

    /// True once a key has been verified. Read by FetchWorker (app side).
    public var isPro: Bool { defaults?.bool(forKey: Self.proKey) ?? false }

    /// The stored key, so the UI can show it / re-verify on launch.
    public var licenseKey: String? { defaults?.string(forKey: Self.keyKey) }

    public enum LicenseError: Error, LocalizedError, Equatable {
        case invalidKey
        case refunded
        case network(Int)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .invalidKey:    return "License key not recognized."
            case .refunded:      return "This purchase was refunded or disputed."
            case .network(let c): return "Couldn't reach Gumroad (HTTP \(c))."
            case .malformed:     return "Unexpected response from Gumroad."
            }
        }
    }

    /// Verify a key with Gumroad and persist `pro` on success. Throws on any
    /// failure (caller shows the message); leaves the stored flag untouched so a
    /// transient network error can't revoke an already-activated license.
    @discardableResult
    public func activate(key: String, session: URLSession = .shared) async throws -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var req = URLRequest(url: URL(string: "https://api.gumroad.com/v2/licenses/verify")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // increment_uses_count=false so re-verifying on every launch doesn't
        // inflate the seat count and trip Gumroad's per-key usage cap.
        let body = "product_id=\(Self.form(Self.productID))"
            + "&license_key=\(Self.form(trimmed))"
            + "&increment_uses_count=false"
        req.httpBody = Data(body.utf8)

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // Gumroad returns 404 with {"success":false} for an unknown key.
        guard code == 200 || code == 404 else { throw LicenseError.network(code) }

        try Self.verdict(status: code, body: data)   // throws on invalid/refunded/malformed

        defaults?.set(true, forKey: Self.proKey)
        defaults?.set(trimmed, forKey: Self.keyKey)
        return true
    }

    /// Pure decision from Gumroad's HTTP status + JSON body. Split out so the
    /// success / unknown-key / refunded / malformed branches are unit-testable
    /// without a live network call. Returns normally only for a valid, live sale.
    static func verdict(status: Int, body: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw LicenseError.malformed
        }
        guard (json["success"] as? Bool) == true else { throw LicenseError.invalidKey }

        // Reject refunded / disputed / chargebacked purchases — success=true
        // only means the key exists, not that the sale still stands.
        if let purchase = json["purchase"] as? [String: Any] {
            let dead = ["refunded", "disputed", "chargebacked"].contains {
                (purchase[$0] as? Bool) == true
            }
            if dead { throw LicenseError.refunded }
        }
    }

    /// Remove the license (user "deactivate", or a refund detected on re-verify).
    public func clear() {
        defaults?.removeObject(forKey: Self.proKey)
        defaults?.removeObject(forKey: Self.keyKey)
    }

    static func form(_ s: String) -> String {
        // Product id contains '=' and '+'; percent-encode for the form body.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
