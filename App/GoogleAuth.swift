import Foundation
import Network
import AppKit
import DrivePeakKit

// MARK: - Errors

public enum GoogleAuthError: Error, LocalizedError {
    case clientIDMissing
    case listenerFailed(Error)
    case portUnavailable
    case redirectFailed(String)
    case noCode
    case tokenExchangeFailed(Int)
    case noRefreshToken
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .clientIDMissing:      return "GoogleOAuth.plist missing or lacks CLIENT_ID"
        case .listenerFailed(let e): return "Loopback listener failed: \(e)"
        case .portUnavailable:      return "Could not determine bound port"
        case .redirectFailed(let s): return "OAuth redirect error: \(s)"
        case .noCode:               return "No code in redirect"
        case .tokenExchangeFailed(let s): return "Token exchange HTTP \(s)"
        case .noRefreshToken:       return "No refresh_token in response — re-auth required"
        case .decodeFailed:         return "Could not decode token response"
        }
    }
}

// MARK: - ContinuationBox

/// Holds an optional continuation so the loopback handler can safely resume it
/// exactly once regardless of whether the redirect arrives before or after the
/// continuation is stored.  Isolated to MainActor so all mutations are
/// serialised with zero additional locking.
@MainActor
private final class ContinuationBox {
    private var continuation: CheckedContinuation<URL, Error>?
    private var pending: Result<URL, Error>?

    /// Called by the listener once a redirect URL is captured.
    func resolve(_ result: Result<URL, Error>) {
        if let c = continuation {
            continuation = nil
            c.resume(with: result)
        } else {
            pending = result   // arrival before attach — store for attach()
        }
    }

    /// Called once to attach the continuation.  If resolve() already fired,
    /// resumes immediately.
    func attach(_ c: CheckedContinuation<URL, Error>) {
        if let p = pending {
            pending = nil
            c.resume(with: p)
        } else {
            continuation = c
        }
    }
}

// MARK: - GoogleAuth

/// Interactive Google sign-in via loopback OAuth (PKCE desktop flow).
///
/// Opens the system browser, starts a one-shot NWListener on an ephemeral
/// loopback port to catch the redirect, exchanges the code for tokens, fetches
/// the user's email, and persists everything via TokenStore.
///
/// Call `signIn()` from a button action.  It is `@MainActor` because it opens
/// a browser and drives the ContinuationBox; the token exchange and network
/// calls are awaited concurrently but that is fine — `await` releases the
/// actor.
@MainActor
public final class GoogleAuth: ObservableObject {

    private let store: TokenStore
    private let session: URLSession

    @Published public private(set) var email: String?
    @Published public private(set) var lastError: String?

    public init(store: TokenStore = TokenStore(), session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    // MARK: - Public API

    /// Populates `email` from a previously saved session (call on app launch).
    public func restore() {
        email = store.load()?.email
    }

    /// Clears saved tokens and resets the signed-in state.
    public func signOut() {
        try? store.clear()
        email = nil
    }

    /// Runs the full sign-in flow and saves tokens to the keychain.
    /// Throws `GoogleAuthError` on any failure.
    public func signIn() async throws {
        lastError = nil
        do {
            try await _signIn()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func _signIn() async throws {
        guard let clientID = OAuthConfig.clientID() else {
            throw GoogleAuthError.clientIDMissing
        }

        let pkce = PKCE.generate()
        let box  = ContinuationBox()

        // 1. Start loopback listener on an ephemeral port.
        let (listener, port) = try await startListener(box: box)
        defer { listener.cancel() }

        let redirectURI = "http://127.0.0.1:\(port)/oauth"

        // 2. Open the browser.
        let authURL = PKCE.makeAuthURL(clientID: clientID,
                                       redirectURI: redirectURI,
                                       challenge: pkce.challenge)
        NSWorkspace.shared.open(authURL)

        // 3. Wait for the redirect callback.
        // ponytail: no wall-clock timeout — a codeless/garbage first request
        // already resolves with .noCode (see the listener handler), so the
        // common hang is covered. A pure "user abandons the tab" hang remains;
        // add a timeout race if that proves to matter in use.
        let redirectURL = try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            // ContinuationBox is MainActor-isolated; this closure runs on the
            // same actor because signIn() is @MainActor.
            box.attach(c)
        }

        // 4. Extract the code (or surface an error parameter).
        let code = try extractCode(from: redirectURL)

        // 5. Exchange code for tokens.
        let tokens = try await exchangeCode(code,
                                            clientID: clientID,
                                            redirectURI: redirectURI,
                                            verifier: pkce.verifier)

        // 6. Persist — email is set only after save succeeds.
        try store.save(tokens)
        self.email = tokens.email
    }

    // MARK: - Listener

    /// Starts a NWListener on TCP port 0 (ephemeral), resolves `box` once the
    /// first redirect request arrives, and returns the listener + the actual
    /// bound port number.
    private func startListener(box: ContinuationBox) async throws -> (NWListener, UInt16) {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: 0)
        } catch {
            throw GoogleAuthError.listenerFailed(error)
        }

        // Resolve the bound port.
        let port: UInt16 = try await withCheckedThrowingContinuation { portCont in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let p = listener.port?.rawValue {
                        portCont.resume(returning: p)
                    } else {
                        portCont.resume(throwing: GoogleAuthError.portUnavailable)
                    }
                case .failed(let err):
                    portCont.resume(throwing: GoogleAuthError.listenerFailed(err))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak box] conn in
                conn.start(queue: .global())
                // Receive the HTTP request line to extract the URL.
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    guard let data = data,
                          let raw = String(data: data, encoding: .utf8) else { return }
                    // HTTP request line: "GET /oauth?code=…&state=… HTTP/1.1"
                    let requestLine = raw.components(separatedBy: "\r\n").first ?? ""
                    let parts = requestLine.components(separatedBy: " ")
                    let path = parts.count >= 2 ? parts[1] : ""
                    // Build a full URL so URLComponents can parse query items.
                    let full = "http://127.0.0.1\(path)"

                    // Send a minimal HTTP response so the browser doesn't hang.
                    let body = "<html><body><h2>Sign-in complete — you can close this tab.</h2></body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    conn.send(content: Data(response.utf8), completion: .idempotent)

                    // Resolve on the first request that carries a path. A parseable
                    // URL → success; a request line we can't turn into a URL →
                    // failure (rather than a silent hang). Truly empty/garbage
                    // reads fall through and let a later connection resolve.
                    if !path.isEmpty {
                        let result: Result<URL, Error> = URL(string: full)
                            .map { .success($0) } ?? .failure(GoogleAuthError.noCode)
                        Task { @MainActor in
                            box?.resolve(result)
                        }
                    }
                }
            }

            listener.start(queue: .global())
        }

        return (listener, port)
    }

    // MARK: - Code Extraction

    private func extractCode(from url: URL) throws -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let errorParam = components?.queryItems?.first(where: { $0.name == "error" })?.value {
            throw GoogleAuthError.redirectFailed(errorParam)
        }
        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw GoogleAuthError.noCode
        }
        return code
    }

    // MARK: - Token Exchange

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let id_token: String?
    }

    private func exchangeCode(_ code: String,
                               clientID: String,
                               redirectURI: String,
                               verifier: String) async throws -> Tokens {
        var req = URLRequest(url: URL(string: GoogleOAuthEndpoints.token)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // ponytail: percent-encode each value — codes/verifiers/client_ids can contain URL-reserved chars
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        let body = [
            "code=\(enc(code))",
            "client_id=\(enc(clientID))",
            "redirect_uri=\(enc(redirectURI))",
            "code_verifier=\(enc(verifier))",
            "grant_type=authorization_code",
        ].joined(separator: "&")
        req.httpBody = Data(body.utf8)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GoogleAuthError.tokenExchangeFailed(status) }

        guard let tokenResp = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw GoogleAuthError.decodeFailed
        }
        guard let refreshToken = tokenResp.refresh_token else {
            throw GoogleAuthError.noRefreshToken
        }

        let email = await fetchEmail(accessToken: tokenResp.access_token)
        let expiry = Date().addingTimeInterval(TimeInterval(tokenResp.expires_in))

        return Tokens(accessToken: tokenResp.access_token,
                      refreshToken: refreshToken,
                      expiry: expiry,
                      email: email)
    }

    // MARK: - Userinfo

    private struct UserInfoResponse: Decodable { let email: String? }

    /// Returns the user's email or nil on any failure (non-fatal — sign-in still succeeds).
    private func fetchEmail(accessToken: String) async -> String? {
        guard let url = URL(string: GoogleOAuthEndpoints.userinfo) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(UserInfoResponse.self, from: data) else {
            return nil
        }
        return info.email
    }
}
