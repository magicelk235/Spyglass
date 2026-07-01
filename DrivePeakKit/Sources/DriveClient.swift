import Foundation

public struct DriveMetadata: Equatable, Decodable {
    public let name: String
    public let modifiedTime: String
}

public enum DriveError: Error, Equatable {
    case notAuthed, http(Int), refreshFailed, decode
}

/// Talks to the Drive v3 API. Refreshes the access token lazily on expiry or a
/// 401 and retries the failed call exactly once. Injectable session for tests.
public final class DriveClient {
    private let store: TokenStore
    private let session: URLSession
    private let clientID: String
    private let clientSecret: String?

    public init(store: TokenStore, session: URLSession = .shared, clientID: String, clientSecret: String? = nil) {
        self.store = store
        self.session = session
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public func exportPDF(docID: String) async throws -> Data {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(docID)/export")!
        c.queryItems = [.init(name: "mimeType", value: "application/pdf")]
        return try await authedData(url: c.url!)
    }

    public func metadata(docID: String) async throws -> DriveMetadata {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(docID)")!
        c.queryItems = [.init(name: "fields", value: "name,modifiedTime")]
        let data = try await authedData(url: c.url!)
        guard let m = try? JSONDecoder().decode(DriveMetadata.self, from: data) else {
            throw DriveError.decode
        }
        return m
    }

    // MARK: - Auth plumbing

    private func authedData(url: URL) async throws -> Data {
        var refreshed = false
        var token = try await validAccessToken(didRefresh: &refreshed)
        var (data, status) = try await get(url, token: token)
        if status == 401, !refreshed {
            // ponytail: single-caller (one preview at a time); add actor isolation if DriveClient ever shared across concurrent callers
            token = try await refresh()
            (data, status) = try await get(url, token: token)
        }
        guard (200..<300).contains(status) else { throw DriveError.http(status) }
        // A 200 with an empty body (Drive occasionally does this for a still-
        // converting or oversized export) is not usable — treat it as an error
        // so it never gets cached and poisons the offline fallback.
        guard !data.isEmpty else { throw DriveError.http(status) }
        return data
    }

    /// Returns a valid access token. Sets `didRefresh` to true if a refresh was performed.
    private func validAccessToken(didRefresh: inout Bool) async throws -> String {
        guard let t = store.load() else { throw DriveError.notAuthed }
        if t.isExpired {
            didRefresh = true
            return try await refresh()
        }
        return t.accessToken
    }

    private func get(_ url: URL, token: String) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private struct RefreshResponse: Decodable { let access_token: String; let expires_in: Int }

    private func refresh() async throws -> String {
        guard let old = store.load() else { throw DriveError.notAuthed }
        var req = URLRequest(url: URL(string: GoogleOAuthEndpoints.token)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // FIX 3: percent-encode values so tokens with / + = don't corrupt the form body
        func encode(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        var fields = [
            "client_id=\(encode(clientID))",
            "refresh_token=\(encode(old.refreshToken))",
            "grant_type=refresh_token",
        ]
        // Desktop-app clients require the secret on refresh too (see OAuthConfig).
        if let secret = clientSecret { fields.append("client_secret=\(encode(secret))") }
        let body = fields.joined(separator: "&")
        req.httpBody = Data(body.utf8)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let r = try? JSONDecoder().decode(RefreshResponse.self, from: data) else {
            throw DriveError.refreshFailed
        }
        let updated = Tokens(accessToken: r.access_token,
                             refreshToken: old.refreshToken,
                             expiry: Date().addingTimeInterval(sanitizedLifetime(r.expires_in)),
                             email: old.email)
        try store.save(updated)
        return r.access_token
    }
}

/// Clamps an OAuth `expires_in` (seconds) to a sane positive lifetime. A
/// negative or zero value from a malformed or hostile token response would mint
/// an already-expired token and drive an infinite refresh loop; floor it so the
/// token is usable for at least a short window. Values are also capped to avoid
/// absurd far-future expiries.
public func sanitizedLifetime(_ expiresIn: Int) -> TimeInterval {
    let minLifetime = 60          // at least a minute of usability
    let maxLifetime = 24 * 3600   // Google access tokens are ~1h; cap at a day
    return TimeInterval(min(max(expiresIn, minLifetime), maxLifetime))
}
