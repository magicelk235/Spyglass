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

    public init(store: TokenStore, session: URLSession = .shared, clientID: String) {
        self.store = store
        self.session = session
        self.clientID = clientID
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
        var token = try await validAccessToken()
        var (data, status) = try await get(url, token: token)
        if status == 401 {
            token = try await refresh()          // one retry after refresh
            (data, status) = try await get(url, token: token)
        }
        guard (200..<300).contains(status) else { throw DriveError.http(status) }
        return data
    }

    private func validAccessToken() async throws -> String {
        guard let t = store.load() else { throw DriveError.notAuthed }
        return t.isExpired ? try await refresh() : t.accessToken
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
        let body = [
            "client_id": clientID,
            "refresh_token": old.refreshToken,
            "grant_type": "refresh_token",
        ].map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        req.httpBody = Data(body.utf8)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let r = try? JSONDecoder().decode(RefreshResponse.self, from: data) else {
            throw DriveError.refreshFailed
        }
        let updated = Tokens(accessToken: r.access_token,
                             refreshToken: old.refreshToken,
                             expiry: Date().addingTimeInterval(TimeInterval(r.expires_in)),
                             email: old.email)
        try store.save(updated)
        return r.access_token
    }
}
