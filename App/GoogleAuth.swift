import Foundation
import Network
import AppKit
import SpyglassKit

public extension Notification.Name {
    /// Posted by GoogleAuth after a successful sign-in.
    static let spyglassDidSignIn = Notification.Name("spyglassDidSignIn")
}

// MARK: - Errors

public enum GoogleAuthError: Error, LocalizedError {
    case clientIDMissing
    case listenerFailed(Error)
    case portUnavailable
    case redirectFailed(String)
    case noCode
    case tokenExchangeFailed(Int, String)
    case noRefreshToken
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .clientIDMissing:      return "GoogleOAuth.plist missing or lacks CLIENT_ID"
        case .listenerFailed(let e): return "Loopback listener failed: \(e)"
        case .portUnavailable:      return "Could not determine bound port"
        case .redirectFailed(let s): return "OAuth redirect error: \(s)"
        case .noCode:               return "No code in redirect"
        case .tokenExchangeFailed(let s, let d): return "Token exchange HTTP \(s): \(d)"
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
    /// True while a sign-in flow is running, so the UI can disable the button
    /// and we can reject a concurrent second flow (which would open a second
    /// browser tab and a second loopback listener).
    @Published public private(set) var isSigningIn = false

    public init(store: TokenStore = TokenStore(), session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    // MARK: - Public API

    /// Populates `email` from a previously saved session (call on app launch).
    public func restore() {
        email = store.load()?.email
    }

    /// Clears saved tokens and resets the signed-in state. Also revokes the
    /// refresh token at Google so the grant is killed server-side, not just
    /// forgotten locally — fire-and-forget: local sign-out must succeed even if
    /// the network call fails.
    public func signOut() {
        if let token = store.load()?.refreshToken {
            let session = self.session
            Task.detached {
                var req = URLRequest(url: URL(string: GoogleOAuthEndpoints.revoke)!)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                let enc = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
                req.httpBody = Data("token=\(enc)".utf8)
                _ = try? await session.data(for: req)
            }
        }
        try? store.clear()
        email = nil
    }

    /// Runs the full sign-in flow and saves tokens to the keychain.
    /// Throws `GoogleAuthError` on any failure.
    public func signIn() async throws {
        guard !isSigningIn else { return }   // reject concurrent sign-in
        isSigningIn = true
        lastError = nil
        defer { isSigningIn = false }
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
        let clientSecret = OAuthConfig.clientSecret()

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
                                            clientSecret: clientSecret,
                                            redirectURI: redirectURI,
                                            verifier: pkce.verifier)

        // 6. Persist — email is set only after save succeeds.
        try store.save(tokens)
        self.email = tokens.email
        // Tell the scanner to sweep now: pre-launch stubs couldn't be fetched
        // without a token, so a fresh sign-in should enqueue them immediately
        // rather than waiting for the next app launch.
        NotificationCenter.default.post(name: .spyglassDidSignIn, object: nil)
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
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    if let p = listener?.port?.rawValue {
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

                    // Only the OAuth redirect matters. Browsers routinely probe
                    // loopback origins (GET /favicon.ico, etc.); those must fall
                    // through so a probe doesn't get mistaken for the callback
                    // and abort sign-in with .noCode. Match the redirect path.
                    guard path.hasPrefix("/oauth") else {
                        conn.cancel()   // ignore the probe; a later connection carries the code
                        return
                    }
                    // Build a full URL so URLComponents can parse query items.
                    let full = "http://127.0.0.1\(path)"

                    // Send a styled response so the browser doesn't hang.
                    // charset=utf-8 (header + meta) fixes the em-dash mojibake.
                    let body = "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Spyglass</title><style>:root{color-scheme:light dark}html,body{height:100%;margin:0}body{display:flex;align-items:center;justify-content:center;font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#f5f5f7;color:#1d1d1f}@media(prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}}.card{text-align:center;padding:40px 48px}.mark{font-size:15px;font-weight:600;letter-spacing:.04em;color:#B8945F;margin:0 0 20px}h1{font-size:22px;font-weight:600;margin:0 0 8px}p{font-size:15px;opacity:.6;margin:0}</style></head><body><div class=\"card\"><p class=\"mark\">SPYGLASS</p><h1>You're signed in</h1><p>You can close this tab and return to the app.</p></div></body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    conn.send(content: Data(response.utf8), completion: .idempotent)

                    // Parseable URL → success; a redirect line we can't turn into
                    // a URL → failure (rather than a silent hang).
                    let result: Result<URL, Error> = URL(string: full)
                        .map { .success($0) } ?? .failure(GoogleAuthError.noCode)
                    Task { @MainActor in
                        box?.resolve(result)
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
                               clientSecret: String?,
                               redirectURI: String,
                               verifier: String) async throws -> Tokens {
        var req = URLRequest(url: URL(string: GoogleOAuthEndpoints.token)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // ponytail: percent-encode each value — codes/verifiers/client_ids can contain URL-reserved chars
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        var fields = [
            "code=\(enc(code))",
            "client_id=\(enc(clientID))",
            "redirect_uri=\(enc(redirectURI))",
            "code_verifier=\(enc(verifier))",
            "grant_type=authorization_code",
        ]
        // Desktop-app OAuth clients require the secret even with PKCE.
        if let clientSecret { fields.append("client_secret=\(enc(clientSecret))") }
        let body = fields.joined(separator: "&")
        req.httpBody = Data(body.utf8)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw GoogleAuthError.tokenExchangeFailed(status, detail)
        }

        guard let tokenResp = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw GoogleAuthError.decodeFailed
        }
        guard let refreshToken = tokenResp.refresh_token else {
            throw GoogleAuthError.noRefreshToken
        }

        let email = await fetchEmail(accessToken: tokenResp.access_token)
        let expiry = Date().addingTimeInterval(sanitizedLifetime(tokenResp.expires_in))

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
