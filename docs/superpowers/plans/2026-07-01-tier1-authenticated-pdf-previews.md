# Tier 1 — Authenticated PDF Previews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When signed into Google, pressing Space on an exportable Google file renders the real document (Drive PDF export) in Quick Look; everything else falls back to the Tier 0 card.

**Architecture:** The app performs loopback OAuth (PKCE) and stores tokens in a shared Keychain group. The sandboxed Quick Look extension reads the token and fetches/renders the PDF itself on Space-press, with a timeout and Tier 0 fallback. A shared App Group container caches exported PDFs for instant re-open.

**Tech Stack:** Swift 5, SwiftUI, PDFKit, Foundation URLSession, Security (Keychain), Network (loopback listener), XcodeGen, XCTest.

## Global Constraints

- macOS deployment target: **14.0** (copied from `project.yml`).
- Swift version: **5.0**.
- No new third-party dependencies — Foundation / Security / PDFKit / Network only.
- Shared identifiers (verbatim): Keychain group `$(DEVELOPMENT_TEAM).com.spyglass.shared`; App Group `group.com.spyglass.shared`.
- OAuth scope (verbatim): `https://www.googleapis.com/auth/drive.readonly` and `https://www.googleapis.com/auth/userinfo.email`.
- `client_secret` is **never** embedded — PKCE desktop flow only.
- Signing stays ad-hoc (`CODE_SIGN_IDENTITY: "-"`) with empty `DEVELOPMENT_TEAM` until the Apple account lands; all code must compile and all unit tests must pass under ad-hoc today.
- Commit style: no Co-Authored-By / attribution footer.
- All new shared logic lives in `SpyglassKit/Sources`; unit tests in `Tests/`.
- Headless build/test command (verbatim):
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Spyglass.xcodeproj -scheme SpyglassKit -destination 'platform=macOS' test -derivedDataPath /tmp/spyglass-dd`
- Regenerate project after any `project.yml` / plist / entitlements change:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate`

---

## File Structure

**Create (SpyglassKit — shared, unit-tested):**
- `SpyglassKit/Sources/Tokens.swift` — the `Tokens` value type.
- `SpyglassKit/Sources/PKCE.swift` — PKCE verifier/challenge + auth-URL assembly (pure, testable).
- `SpyglassKit/Sources/TokenStore.swift` — Keychain read/write with an injectable backend.
- `SpyglassKit/Sources/DriveClient.swift` — Drive export/metadata + 401-refresh, injectable `URLSession`.
- `SpyglassKit/Sources/PreviewCache.swift` — App Group PDF cache keyed by docID + modifiedTime.
- `SpyglassKit/Sources/OAuthConfig.swift` — loads `client_id` from `GoogleOAuth.plist`.

**Create (App — interactive, not unit-tested):**
- `App/GoogleAuth.swift` — loopback listener + code exchange (glues PKCE + DriveClient token endpoint + TokenStore).

**Create (config):**
- `Secrets.xcconfig` (gitignored) — `DEVELOPMENT_TEAM =` (empty today).
- `GoogleOAuth.plist` (gitignored) — `{ CLIENT_ID: … }`.

**Modify:**
- `project.yml` — App Group + Keychain entitlements refs, `Secrets.xcconfig` base config, PDFKit link.
- `App/App.entitlements` — add App Group + Keychain group.
- `Preview/Preview.entitlements` — add App Group + Keychain group.
- `Preview/PreviewViewController.swift` — Tier 1 fetch-render-with-fallback.
- `App/ContentView.swift` — sign-in / sign-out row.
- `.gitignore` — add `GoogleOAuth.plist` (already ignores `client_secret_*.json`).

**Test:**
- `Tests/PKCETests.swift`, `Tests/TokenStoreTests.swift`, `Tests/DriveClientTests.swift`, `Tests/PreviewCacheTests.swift`.

---

## Task 1: `Tokens` value type

**Files:**
- Create: `SpyglassKit/Sources/Tokens.swift`
- Test: covered indirectly (Task 3/4); no standalone test — it's a plain struct.

**Interfaces:**
- Produces: `struct Tokens: Codable, Equatable, Sendable { accessToken: String; refreshToken: String; expiry: Date; email: String? }`, memberwise-usable, plus `var isExpired: Bool` (`expiry <= Date()`).

- [ ] **Step 1: Write the type**

```swift
import Foundation

/// OAuth tokens persisted by the app and read by the extension.
/// `refreshToken` is long-lived → lives in the Keychain (see TokenStore).
public struct Tokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiry: Date
    public let email: String?

    public init(accessToken: String, refreshToken: String, expiry: Date, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiry = expiry
        self.email = email
    }

    /// True once the access token is at/after its expiry (refresh needed).
    public var isExpired: Bool { expiry <= Date() }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Spyglass.xcodeproj -scheme SpyglassKit -destination 'platform=macOS' build -derivedDataPath /tmp/spyglass-dd`
Expected: BUILD SUCCEEDED (regenerate project first if the file isn't picked up: `xcodegen generate`).

- [ ] **Step 3: Commit**

```bash
git add SpyglassKit/Sources/Tokens.swift
git commit -m "Add Tokens value type for OAuth persistence"
```

---

## Task 2: PKCE + auth-URL assembly

**Files:**
- Create: `SpyglassKit/Sources/PKCE.swift`
- Test: `Tests/PKCETests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct PKCE { let verifier: String; let challenge: String }`
  - `static func PKCE.generate() -> PKCE` (verifier: 64 URL-safe chars; challenge: base64url(SHA256(verifier)) no padding).
  - `enum GoogleOAuthEndpoints { static let auth = "https://accounts.google.com/o/oauth2/auth"; static let token = "https://oauth2.googleapis.com/token"; static let scopes = ["https://www.googleapis.com/auth/drive.readonly", "https://www.googleapis.com/auth/userinfo.email"] }`
  - `static func makeAuthURL(clientID: String, redirectURI: String, challenge: String) -> URL` — assembles the auth request with `code_challenge_method=S256`, space-joined scopes, `access_type=offline`, `prompt=consent`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CryptoKit
@testable import SpyglassKit

final class PKCETests: XCTestCase {
    func testChallengeIsBase64URLSHA256OfVerifier() {
        let pkce = PKCE.generate()
        // Recompute the expected challenge from the verifier.
        let digest = SHA256.hash(data: Data(pkce.verifier.utf8))
        let expected = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(pkce.challenge, expected)
        XCTAssertFalse(pkce.challenge.contains("="))
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43) // RFC 7636 min
    }

    func testAuthURLContainsRequiredParams() {
        let url = PKCE.makeAuthURL(
            clientID: "cid.apps.googleusercontent.com",
            redirectURI: "http://127.0.0.1:5555/",
            challenge: "CHAL"
        )
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://accounts.google.com/o/oauth2/auth?"))
        XCTAssertTrue(s.contains("client_id=cid.apps.googleusercontent.com"))
        XCTAssertTrue(s.contains("code_challenge=CHAL"))
        XCTAssertTrue(s.contains("code_challenge_method=S256"))
        XCTAssertTrue(s.contains("response_type=code"))
        XCTAssertTrue(s.contains("access_type=offline"))
        // scope is URL-encoded; check one scope fragment survives
        XCTAssertTrue(s.contains("drive.readonly"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Spyglass.xcodeproj -scheme SpyglassKit -destination 'platform=macOS' test -derivedDataPath /tmp/spyglass-dd`
Expected: FAIL — `PKCE` / `makeAuthURL` not defined (compile error).

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import CryptoKit

/// PKCE (RFC 7636) verifier/challenge pair and Google OAuth URL assembly.
/// Pure and deterministic given the verifier, so the challenge derivation is
/// unit-tested; only the random verifier bytes vary.
public struct PKCE {
    public let verifier: String
    public let challenge: String

    public static func generate() -> PKCE {
        // 32 random bytes → 43-char base64url verifier (RFC 7636 unreserved).
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64url(Data(bytes))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return PKCE(verifier: verifier, challenge: base64url(Data(digest)))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func makeAuthURL(clientID: String, redirectURI: String, challenge: String) -> URL {
        var c = URLComponents(string: GoogleOAuthEndpoints.auth)!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GoogleOAuthEndpoints.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return c.url!
    }
}

public enum GoogleOAuthEndpoints {
    public static let auth = "https://accounts.google.com/o/oauth2/auth"
    public static let token = "https://oauth2.googleapis.com/token"
    public static let userinfo = "https://www.googleapis.com/oauth2/v3/userinfo"
    public static let scopes = [
        "https://www.googleapis.com/auth/drive.readonly",
        "https://www.googleapis.com/auth/userinfo.email",
    ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same test command as Step 2.
Expected: PASS (PKCETests 2 tests).

- [ ] **Step 5: Commit**

```bash
git add SpyglassKit/Sources/PKCE.swift Tests/PKCETests.swift
git commit -m "Add PKCE generation and Google auth URL assembly with tests"
```

---

## Task 3: `TokenStore` (Keychain, injectable backend)

**Files:**
- Create: `SpyglassKit/Sources/TokenStore.swift`
- Test: `Tests/TokenStoreTests.swift`

**Interfaces:**
- Consumes: `Tokens` (Task 1).
- Produces:
  - `protocol KeychainBackend { func set(_ data: Data, account: String) throws; func get(account: String) -> Data?; func delete(account: String) throws }`
  - `struct TokenStore { init(backend: KeychainBackend = SystemKeychain(group: "com.spyglass.shared")); func save(_ tokens: Tokens) throws; func load() -> Tokens?; func clear() throws }`
  - `final class SystemKeychain: KeychainBackend` — real Keychain via `kSecClassGenericPassword` + `kSecAttrAccessGroup`.
  - The account key is the constant `"google-oauth"`.

Rationale for the backend protocol: the real Keychain needs entitlements we can't sign ad-hoc yet, so tests inject an in-memory backend. `TokenStore`'s encode/decode logic is what we test; `SystemKeychain` is a thin, untested shim exercised manually once the account lands.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SpyglassKit

/// In-memory backend so TokenStore's encode/decode is testable without the
/// entitlement-gated system Keychain.
final class MemoryKeychain: KeychainBackend {
    private var store: [String: Data] = [:]
    func set(_ data: Data, account: String) throws { store[account] = data }
    func get(account: String) -> Data? { store[account] }
    func delete(account: String) throws { store[account] = nil }
}

final class TokenStoreTests: XCTestCase {
    func testSaveLoadRoundTrip() throws {
        let store = TokenStore(backend: MemoryKeychain())
        let t = Tokens(accessToken: "AT", refreshToken: "RT",
                       expiry: Date(timeIntervalSince1970: 1_000_000), email: "me@x.com")
        try store.save(t)
        XCTAssertEqual(store.load(), t)
    }

    func testLoadNilWhenEmpty() {
        XCTAssertNil(TokenStore(backend: MemoryKeychain()).load())
    }

    func testClearRemoves() throws {
        let store = TokenStore(backend: MemoryKeychain())
        try store.save(Tokens(accessToken: "A", refreshToken: "R", expiry: .distantFuture, email: nil))
        try store.clear()
        XCTAssertNil(store.load())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: same test command.
Expected: FAIL — `TokenStore` / `KeychainBackend` not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import Security

/// Storage backend abstraction so the encode/decode path is unit-testable
/// without the entitlement-gated system Keychain.
public protocol KeychainBackend {
    func set(_ data: Data, account: String) throws
    func get(account: String) -> Data?
    func delete(account: String) throws
}

public struct TokenStore {
    private static let account = "google-oauth"
    private let backend: KeychainBackend

    public init(backend: KeychainBackend = SystemKeychain(group: "com.spyglass.shared")) {
        self.backend = backend
    }

    public func save(_ tokens: Tokens) throws {
        try backend.set(try JSONEncoder().encode(tokens), account: Self.account)
    }

    public func load() -> Tokens? {
        guard let data = backend.get(account: Self.account) else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    public func clear() throws {
        try backend.delete(account: Self.account)
    }
}

/// Real Keychain backed by a shared access group. Requires the
/// keychain-access-groups entitlement ($(DEVELOPMENT_TEAM).com.spyglass.shared),
/// which needs a paid Apple Developer Team ID to sign — exercised manually once
/// the account lands. ponytail: thin shim, no unit test; logic lives in TokenStore.
public final class SystemKeychain: KeychainBackend {
    private let group: String
    public init(group: String) { self.group = group }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: group]
    }

    public func set(_ data: Data, account: String) throws {
        try delete(account: account)
        var q = baseQuery(account)
        q[kSecValueData as String] = data
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func get(account: String) -> Data? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    public enum KeychainError: Error { case status(OSStatus) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same test command.
Expected: PASS (TokenStoreTests 3 tests).

- [ ] **Step 5: Commit**

```bash
git add SpyglassKit/Sources/TokenStore.swift Tests/TokenStoreTests.swift
git commit -m "Add TokenStore with injectable Keychain backend and tests"
```

---

## Task 4: `DriveClient` (export/metadata + 401 refresh)

**Files:**
- Create: `SpyglassKit/Sources/DriveClient.swift`
- Test: `Tests/DriveClientTests.swift`

**Interfaces:**
- Consumes: `Tokens` (Task 1), `TokenStore` (Task 3), `GoogleOAuthEndpoints` (Task 2), `WorkspaceType` (existing).
- Produces:
  - `struct DriveMetadata: Equatable { let name: String; let modifiedTime: String }`
  - `final class DriveClient { init(store: TokenStore, session: URLSession = .shared, clientID: String) }`
  - `func exportPDF(docID: String) async throws -> Data`
  - `func metadata(docID: String) async throws -> DriveMetadata`
  - `enum DriveError: Error { case notAuthed, http(Int), refreshFailed, decode }`
  - Internal `refreshIfNeeded()` and a single retry on HTTP 401.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SpyglassKit

/// URLProtocol stub: maps a URL substring → (status, body). Records requests.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [(match: String, status: Int, body: Data)] = []
    nonisolated(unsafe) static var requestedURLs: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        let urlString = request.url?.absoluteString ?? ""
        Self.requestedURLs.append(urlString)
        let route = Self.routes.first { urlString.contains($0.match) }
        let status = route?.status ?? 404
        let body = route?.body ?? Data()
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DriveClientTests: XCTestCase {
    private func makeClient(tokens: Tokens) -> DriveClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let store = TokenStore(backend: MemoryKeychain())
        try? store.save(tokens)
        return DriveClient(store: store, session: URLSession(configuration: cfg),
                           clientID: "cid")
    }

    override func setUp() { StubURLProtocol.routes = []; StubURLProtocol.requestedURLs = [] }

    func testExportPDFReturnsBody() async throws {
        StubURLProtocol.routes = [("/export", 200, Data("PDFBYTES".utf8))]
        let c = makeClient(tokens: Tokens(accessToken: "AT", refreshToken: "RT",
                                          expiry: .distantFuture, email: nil))
        let data = try await c.exportPDF(docID: "DOC1")
        XCTAssertEqual(String(data: data, encoding: .utf8), "PDFBYTES")
        XCTAssertTrue(StubURLProtocol.requestedURLs.contains { $0.contains("files/DOC1/export") })
        XCTAssertTrue(StubURLProtocol.requestedURLs.contains { $0.contains("mimeType=application/pdf") })
    }

    func test401TriggersRefreshThenRetrySucceeds() async throws {
        // First export → 401; token refresh → 200 with new token; export retry → 200.
        StubURLProtocol.routes = [
            ("/token", 200, Data(#"{"access_token":"NEW","expires_in":3600}"#.utf8)),
            ("/export", 200, Data("OK".utf8)),
        ]
        // Force expired so refresh path is taken deterministically.
        let c = makeClient(tokens: Tokens(accessToken: "OLD", refreshToken: "RT",
                                          expiry: .distantPast, email: nil))
        let data = try await c.exportPDF(docID: "DOC1")
        XCTAssertEqual(String(data: data, encoding: .utf8), "OK")
        XCTAssertTrue(StubURLProtocol.requestedURLs.contains { $0.contains("/token") })
    }

    func testMetadataDecodes() async throws {
        StubURLProtocol.routes = [
            ("fields=", 200, Data(#"{"name":"My Doc","modifiedTime":"2026-07-01T00:00:00Z"}"#.utf8)),
        ]
        let c = makeClient(tokens: Tokens(accessToken: "AT", refreshToken: "RT",
                                          expiry: .distantFuture, email: nil))
        let m = try await c.metadata(docID: "DOC1")
        XCTAssertEqual(m, DriveMetadata(name: "My Doc", modifiedTime: "2026-07-01T00:00:00Z"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: same test command.
Expected: FAIL — `DriveClient` / `DriveMetadata` / `DriveError` not defined.

- [ ] **Step 3: Write the implementation**

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: same test command.
Expected: PASS (DriveClientTests 3 tests).

- [ ] **Step 5: Commit**

```bash
git add SpyglassKit/Sources/DriveClient.swift Tests/DriveClientTests.swift
git commit -m "Add DriveClient with PDF export, metadata, and 401-refresh retry"
```

---

## Task 5: `PreviewCache` (App Group container)

**Files:**
- Create: `SpyglassKit/Sources/PreviewCache.swift`
- Test: `Tests/PreviewCacheTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct PreviewCache { init(directory: URL) }` (inject a temp dir in tests; app/extension pass the App Group container)
  - `static func groupContainerURL(groupID: String = "group.com.spyglass.shared") -> URL?` (real container; nil if unavailable)
  - `func cachedPDF(docID: String, modifiedTime: String) -> Data?` (nil if missing or stale)
  - `func store(docID: String, modifiedTime: String, pdf: Data) throws`
  - Layout: `<dir>/previews/<docID>.pdf` + `<dir>/previews/<docID>.meta` (meta = modifiedTime string).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SpyglassKit

final class PreviewCacheTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("dp-cache-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testStoreThenHitWhenModifiedTimeMatches() throws {
        let cache = PreviewCache(directory: tempDir())
        try cache.store(docID: "D1", modifiedTime: "T1", pdf: Data("PDF".utf8))
        XCTAssertEqual(cache.cachedPDF(docID: "D1", modifiedTime: "T1"),
                       Data("PDF".utf8))
    }

    func testMissWhenModifiedTimeDiffers() throws {
        let cache = PreviewCache(directory: tempDir())
        try cache.store(docID: "D1", modifiedTime: "T1", pdf: Data("PDF".utf8))
        XCTAssertNil(cache.cachedPDF(docID: "D1", modifiedTime: "T2")) // stale
    }

    func testMissWhenAbsent() {
        XCTAssertNil(PreviewCache(directory: tempDir()).cachedPDF(docID: "X", modifiedTime: "T"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: same test command.
Expected: FAIL — `PreviewCache` not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Caches exported PDFs in a directory (the shared App Group container in
/// production), keyed by docID and invalidated by the file's modifiedTime.
/// ponytail: no eviction yet — add LRU/size cap if <container>/previews grows.
public struct PreviewCache {
    private let previewsDir: URL

    public init(directory: URL) {
        self.previewsDir = directory.appendingPathComponent("previews", isDirectory: true)
    }

    public static func groupContainerURL(groupID: String = "group.com.spyglass.shared") -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    public func cachedPDF(docID: String, modifiedTime: String) -> Data? {
        guard let meta = try? String(contentsOf: metaURL(docID), encoding: .utf8),
              meta == modifiedTime,
              let data = try? Data(contentsOf: pdfURL(docID))
        else { return nil }
        return data
    }

    public func store(docID: String, modifiedTime: String, pdf: Data) throws {
        try FileManager.default.createDirectory(at: previewsDir, withIntermediateDirectories: true)
        try pdf.write(to: pdfURL(docID))
        try modifiedTime.write(to: metaURL(docID), atomically: true, encoding: .utf8)
    }

    private func pdfURL(_ docID: String) -> URL { previewsDir.appendingPathComponent("\(docID).pdf") }
    private func metaURL(_ docID: String) -> URL { previewsDir.appendingPathComponent("\(docID).meta") }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same test command.
Expected: PASS (PreviewCacheTests 3 tests).

- [ ] **Step 5: Commit**

```bash
git add SpyglassKit/Sources/PreviewCache.swift Tests/PreviewCacheTests.swift
git commit -m "Add PreviewCache keyed by docID and modifiedTime"
```

---

## Task 6: `OAuthConfig` (client_id loader)

**Files:**
- Create: `SpyglassKit/Sources/OAuthConfig.swift`
- Create: `GoogleOAuth.plist` (gitignored)
- Modify: `.gitignore`

**Interfaces:**
- Produces: `enum OAuthConfig { static func clientID(bundle: Bundle) -> String? }` — reads `GoogleOAuth.plist` (`CLIENT_ID`) from the given bundle's resources.

No standalone unit test — it's a plist read; correctness is verified when auth runs. ponytail: trivial I/O, no test.

- [ ] **Step 1: Add gitignore entry**

Append to `.gitignore`:
```
GoogleOAuth.plist
```

- [ ] **Step 2: Create the plist (from the downloaded client_secret JSON's client_id)**

`GoogleOAuth.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CLIENT_ID</key>
    <string>310514018878-g0qn1e7olbgjm8gljomi6r01mpr214m2.apps.googleusercontent.com</string>
</dict>
</plist>
```

- [ ] **Step 3: Write the loader**

```swift
import Foundation

/// Reads the Google OAuth client_id from GoogleOAuth.plist bundled at build
/// time. The plist is gitignored; see README for creating it. No client_secret
/// is stored — the PKCE desktop flow doesn't need one.
public enum OAuthConfig {
    public static func clientID(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "GoogleOAuth", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) else { return nil }
        return dict["CLIENT_ID"] as? String
    }
}
```

- [ ] **Step 4: Wire the plist into both bundles (project.yml) and regenerate**

Under `Spyglass` target and `SpyglassPreview` target `sources`, add the resource so it's copied into each bundle. In `project.yml`, add to each target:
```yaml
    sources:
      - <existing path>
      - path: GoogleOAuth.plist
        buildPhase: resources
```
(App keeps `App`; Preview keeps `Preview`; add the plist line to both.)

Then: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate`

- [ ] **Step 5: Build to verify**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Spyglass.xcodeproj -scheme Spyglass -configuration Release build -derivedDataPath /tmp/spyglass-dd`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add .gitignore SpyglassKit/Sources/OAuthConfig.swift project.yml
git commit -m "Add OAuthConfig client_id loader; bundle gitignored GoogleOAuth.plist"
```

---

## Task 7: Entitlements + Secrets.xcconfig (build-today provision)

**Files:**
- Create: `Secrets.xcconfig` (gitignored — already ignored)
- Modify: `App/App.entitlements`, `Preview/Preview.entitlements`, `project.yml`

**Interfaces:** none (build config only).

Goal: add the App Group + Keychain entitlements and route `DEVELOPMENT_TEAM` through `Secrets.xcconfig` (empty today). Everything must still build ad-hoc.

- [ ] **Step 1: Create Secrets.xcconfig (empty team for now)**

`Secrets.xcconfig`:
```
// Filled once the paid Apple Developer account lands. Empty = ad-hoc signing.
DEVELOPMENT_TEAM =
```

- [ ] **Step 2: Add App Group + Keychain to App/App.entitlements**

Add inside the `<dict>`:
```xml
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.spyglass.shared</string>
    </array>
    <key>keychain-access-groups</key>
    <array>
        <string>$(AppIdentifierPrefix)com.spyglass.shared</string>
    </array>
```

- [ ] **Step 3: Add the same two keys to Preview/Preview.entitlements**

(Identical block as Step 2, inside its `<dict>`.)

- [ ] **Step 4: Route Secrets.xcconfig as base config in project.yml**

Add at the top-level `configs`/`settings` — set the project base config file:
```yaml
configFiles:
  Debug: Secrets.xcconfig
  Release: Secrets.xcconfig
```
(Place at the same indent level as `settings:` in project.yml.)

- [ ] **Step 5: Regenerate + build ad-hoc to confirm it still compiles**

Run:
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Spyglass.xcodeproj -scheme Spyglass -configuration Release build -derivedDataPath /tmp/spyglass-dd
```
Expected: BUILD SUCCEEDED. (Ad-hoc signing ignores the empty team; the entitlements are declared but not enforced until signed with a real team. If ad-hoc signing rejects the keychain-access-groups entitlement, note it and proceed — the manual E2E is account-gated anyway; the unit-test scheme `SpyglassKit` does not sign the app and will still pass.)

- [ ] **Step 6: Commit**

```bash
git add App/App.entitlements Preview/Preview.entitlements project.yml
git commit -m "Add App Group + shared Keychain entitlements; route DEVELOPMENT_TEAM via Secrets.xcconfig"
```

---

## Task 8: `GoogleAuth` (app loopback OAuth)

**Files:**
- Create: `App/GoogleAuth.swift`

**Interfaces:**
- Consumes: `PKCE`, `GoogleOAuthEndpoints` (Task 2), `Tokens` (Task 1), `TokenStore` (Task 3), `OAuthConfig` (Task 6).
- Produces:
  - `@MainActor final class GoogleAuth: ObservableObject { @Published var email: String?; init(store: TokenStore) }`
  - `func signIn() async throws` — full loopback flow; on success saves `Tokens` and sets `email`.
  - `func signOut()` — `store.clear()`, `email = nil`.
  - `func restore()` — loads existing email from `store` on launch.

No unit test (interactive network + browser). Its pure pieces (PKCE, URL, token decode) are already tested in Tasks 2/4. ponytail: glue code, manually verified once the account lands.

- [ ] **Step 1: Write the implementation**

```swift
import Foundation
import AppKit
import Network
import SpyglassKit

/// Interactive Google sign-in via loopback OAuth (PKCE desktop flow).
/// Opens the system browser, runs a one-shot local listener to catch the
/// redirect, exchanges the code for tokens, and persists them via TokenStore.
@MainActor
final class GoogleAuth: ObservableObject {
    @Published var email: String?
    private let store: TokenStore

    init(store: TokenStore) { self.store = store }

    func restore() { email = store.load()?.email }
    func signOut() { try? store.clear(); email = nil }

    func signIn() async throws {
        guard let clientID = OAuthConfig.clientID() else { throw AuthError.noClientID }
        let pkce = PKCE.generate()
        let (port, codeFuture) = try startLoopback()
        let redirect = "http://127.0.0.1:\(port)/"
        let authURL = PKCE.makeAuthURL(clientID: clientID, redirectURI: redirect, challenge: pkce.challenge)

        NSWorkspace.shared.open(authURL)
        let code = try await codeFuture()               // waits for the browser redirect
        let tokens = try await exchange(code: code, verifier: pkce.verifier,
                                        clientID: clientID, redirect: redirect)
        try store.save(tokens)
        email = tokens.email
    }

    // MARK: - Loopback listener

    /// Starts an NWListener on an ephemeral port. Returns the port and an async
    /// function that resolves with the `code` query param from the first GET.
    private func startLoopback() throws -> (UInt16, () async throws -> String) {
        let listener = try NWListener(using: .tcp, on: .any)
        var continuation: CheckedContinuation<String, Error>?
        let box = ContinuationBox()

        listener.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard let data, let req = String(data: data, encoding: .utf8) else { return }
                let code = Self.parseCode(fromRequestLine: req)
                let bodyText = code != nil ? "Signed in. You can close this tab." : "Sign-in failed."
                let http = "HTTP/1.1 200 OK\r\nContent-Length: \(bodyText.utf8.count)\r\nConnection: close\r\n\r\n\(bodyText)"
                conn.send(content: Data(http.utf8), completion: .contentProcessed { _ in
                    conn.cancel(); listener.cancel()
                })
                if let code { box.resume(.success(code)) }
                else { box.resume(.failure(AuthError.noCode)) }
            }
        }
        listener.start(queue: .main)

        // Resolve the actual bound port.
        guard let port = listener.port?.rawValue else { throw AuthError.noPort }
        let wait: () async throws -> String = {
            try await withCheckedThrowingContinuation { c in box.attach(c) }
        }
        _ = continuation
        return (port, wait)
    }

    /// Extracts the `code` value from an HTTP request line: `GET /?code=XYZ&... HTTP/1.1`.
    static func parseCode(fromRequestLine req: String) -> String? {
        guard let line = req.split(separator: "\r\n").first,
              let path = line.split(separator: " ").dropFirst().first,
              let comps = URLComponents(string: "http://x\(path)"),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
        else { return nil }
        return code
    }

    // MARK: - Token exchange

    private struct TokenResponse: Decodable {
        let access_token: String; let refresh_token: String?; let expires_in: Int
    }

    private func exchange(code: String, verifier: String, clientID: String, redirect: String) async throws -> Tokens {
        var req = URLRequest(url: URL(string: GoogleOAuthEndpoints.token)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": clientID, "code": code, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": redirect,
        ].map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        req.httpBody = Data(form.utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let r = try? JSONDecoder().decode(TokenResponse.self, from: data),
              let refresh = r.refresh_token else { throw AuthError.exchangeFailed }
        let email = try? await fetchEmail(accessToken: r.access_token)
        return Tokens(accessToken: r.access_token, refreshToken: refresh,
                      expiry: Date().addingTimeInterval(TimeInterval(r.expires_in)), email: email)
    }

    private func fetchEmail(accessToken: String) async throws -> String? {
        var req = URLRequest(url: URL(string: GoogleOAuthEndpoints.userinfo)!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Info: Decodable { let email: String? }
        return (try? JSONDecoder().decode(Info.self, from: data))?.email
    }

    enum AuthError: Error { case noClientID, noPort, noCode, exchangeFailed }
}

/// One-shot continuation holder so the receive handler can resume a caller that
/// attaches slightly later. ponytail: minimal; single sign-in at a time.
private final class ContinuationBox {
    private var stored: Result<String, Error>?
    private var cont: CheckedContinuation<String, Error>?
    func attach(_ c: CheckedContinuation<String, Error>) {
        if let stored { c.resume(with: stored) } else { cont = c }
    }
    func resume(_ r: Result<String, Error>) {
        if let cont { cont.resume(with: r) } else { stored = r }
    }
}
```

- [ ] **Step 2: Add GoogleAuth.swift to the App target (already covered — App/ is a source dir) and regenerate**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate`

- [ ] **Step 3: Build the app to verify it compiles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Spyglass.xcodeproj -scheme Spyglass -configuration Release build -derivedDataPath /tmp/spyglass-dd`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add App/GoogleAuth.swift
git commit -m "Add GoogleAuth loopback OAuth (PKCE) flow in the app"
```

---

## Task 9: Extension Tier 1 render with fallback

**Files:**
- Modify: `Preview/PreviewViewController.swift`
- Modify: `project.yml` (link PDFKit if needed — PDFKit is a system framework, usually auto-linked via import)

**Interfaces:**
- Consumes: `StubParser`, `StubCardView` (existing), `TokenStore`, `DriveClient`, `PreviewCache`, `OAuthConfig`, `WorkspaceType.isExportable` (existing).

Logic: parse → if not exportable or no token → Tier 0. Else metadata → cache hit → PDF; miss → export (≤2s) → cache + PDF. Any failure → Tier 0.

- [ ] **Step 1: Rewrite `preparePreviewOfFile(at:)`**

```swift
import Cocoa
import QuickLookUI
import SwiftUI
import PDFKit
import OSLog
import SpyglassKit

private let log = Logger(subsystem: "com.spyglass.app.preview", category: "preview")

final class PreviewViewController: NSViewController, QLPreviewingController {

    override func loadView() { view = NSView() }

    func preparePreviewOfFile(at url: URL) async throws {
        log.notice("Preview invoked for \(url.lastPathComponent, privacy: .public)")

        let stub: Stub
        do { stub = try StubParser.parse(fileAt: url) }
        catch {
            log.error("Parse failed: \(String(describing: error), privacy: .public)")
            return present(AnyView(UnparseableView(filename: url.lastPathComponent)))
        }

        // Tier 1: rendered PDF when signed in and the type is exportable.
        if stub.type.isExportable, let pdf = await tier1PDF(for: stub) {
            let pdfView = PDFView()
            pdfView.document = PDFDocument(data: pdf)
            pdfView.autoScales = true
            return present(view: pdfView)
        }

        // Tier 0: offline card (default and fallback).
        present(AnyView(StubCardView(stub: stub)))
    }

    /// Returns rendered PDF data, or nil to fall back to Tier 0. Never throws —
    /// any auth/network/timeout problem just yields nil.
    private func tier1PDF(for stub: Stub) async -> Data? {
        let store = TokenStore()
        guard store.load() != nil, let clientID = OAuthConfig.clientID(bundle: .main)
        else { return nil }
        guard let container = PreviewCache.groupContainerURL() else { return nil }
        let cache = PreviewCache(directory: container)
        let client = DriveClient(store: store, clientID: clientID)

        do {
            return try await withTimeout(seconds: 2) {
                let meta = try await client.metadata(docID: stub.docID)
                if let hit = cache.cachedPDF(docID: stub.docID, modifiedTime: meta.modifiedTime) {
                    return hit
                }
                let pdf = try await client.exportPDF(docID: stub.docID)
                try? cache.store(docID: stub.docID, modifiedTime: meta.modifiedTime, pdf: pdf)
                return pdf
            }
        } catch {
            log.error("Tier 1 fell back: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - View plumbing

    private func present(_ root: AnyView) {
        present(view: NSHostingView(rootView: root))
    }
    private func present(view child: NSView) {
        child.frame = view.bounds
        child.autoresizingMask = [.width, .height]
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(child)
    }
}

/// Races an async operation against a timeout; throws TimeoutError if it wins.
private struct TimeoutError: Error {}
private func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private struct UnparseableView: View {
    let filename: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.folder").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(filename).font(.headline).lineLimit(2)
            Text("Not a readable Google Workspace file").font(.callout).foregroundStyle(.secondary)
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Regenerate + build the app (extension is embedded)**

Run:
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Spyglass.xcodeproj -scheme Spyglass -configuration Release build -derivedDataPath /tmp/spyglass-dd
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full unit-test suite (must stay green)**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Spyglass.xcodeproj -scheme SpyglassKit -destination 'platform=macOS' test -derivedDataPath /tmp/spyglass-dd`
Expected: all tests PASS (16 prior + PKCE 2 + TokenStore 3 + DriveClient 3 + PreviewCache 3).

- [ ] **Step 4: Commit**

```bash
git add Preview/PreviewViewController.swift project.yml
git commit -m "Extension: render Drive PDF export when authed, fall back to Tier 0"
```

---

## Task 10: Sign-in UI in the host app

**Files:**
- Modify: `App/ContentView.swift`
- Modify: `App/SpyglassApp.swift` (inject `GoogleAuth`, call `restore()` on launch)

**Interfaces:**
- Consumes: `GoogleAuth` (Task 8), `TokenStore` (Task 3).

- [ ] **Step 1: Inject GoogleAuth in the app entry point**

In `App/SpyglassApp.swift`, create the auth object and pass to `ContentView`:
```swift
import SwiftUI
import SpyglassKit

@main
struct SpyglassApp: App {
    @StateObject private var auth = GoogleAuth(store: TokenStore())

    var body: some Scene {
        Window("Spyglass", id: "main") {
            ContentView()
                .environmentObject(auth)
                .onAppear { auth.restore() }
        }
        .windowResizability(.contentSize)
    }
}
```

- [ ] **Step 2: Add the sign-in row to ContentView**

In `App/ContentView.swift`, add `@EnvironmentObject var auth: GoogleAuth` and insert this block into the sidebar `VStack` (above the usage hints `Spacer()`):
```swift
            Divider()

            if let email = auth.email {
                VStack(alignment: .leading, spacing: 4) {
                    Label(email, systemImage: "person.crop.circle.fill.badge.checkmark")
                        .font(.callout).foregroundStyle(.green).lineLimit(1)
                    Button("Sign out") { auth.signOut() }
                        .buttonStyle(.link).font(.caption)
                }
            } else {
                Button {
                    Task { try? await auth.signIn() }
                } label: {
                    Label("Sign in with Google", systemImage: "person.badge.key")
                }
                Text("Optional — enables rendered document previews.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
```
(And add `@EnvironmentObject private var auth: GoogleAuth` as a property on `ContentView`.)

- [ ] **Step 3: Fix the #Preview to supply the environment object**

At the bottom of `ContentView.swift`:
```swift
#Preview {
    ContentView().environmentObject(GoogleAuth(store: TokenStore()))
}
```

- [ ] **Step 4: Regenerate + build**

Run:
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Spyglass.xcodeproj -scheme Spyglass -configuration Release build -derivedDataPath /tmp/spyglass-dd
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add App/ContentView.swift App/SpyglassApp.swift
git commit -m "Add Google sign-in / sign-out row to the host app"
```

---

## Task 11: README

**Files:**
- Create: `README.md`

**Interfaces:** none.

- [ ] **Step 1: Write the README**

Cover: what Spyglass is (good Quick Look previews for Google Workspace stubs); the two tiers; build/install steps (`xcodegen generate`, the headless `xcodebuild` install command, `xattr -cr`, reopen app once); creating `GoogleOAuth.plist` from the downloaded `client_secret_*.json` (copy the `client_id`); the Apple Developer Team ID step (fill `Secrets.xcconfig`, flip signing) for Tier 1; how to run tests; the known limitation that Tier 1 needs the paid account. Include the fact that Forms/Sites always show the Tier 0 card.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Add README with build, OAuth setup, and Tier 1 signing steps"
```

---

## Self-Review

**1. Spec coverage:**
- GoogleAuth (loopback PKCE) → Task 8. ✅
- TokenStore (shared Keychain) → Task 3. ✅
- DriveClient (export/metadata + 401 refresh) → Task 4. ✅
- PreviewCache (App Group container) → Task 5. ✅
- Extension fetch-render-fallback + 2s timeout → Task 9. ✅
- Sign-in UI → Task 10. ✅
- Config/secrets (GoogleOAuth.plist, gitignore) → Task 6. ✅
- Entitlements + Secrets.xcconfig build-today provision → Task 7. ✅
- PKCE challenge / auth-URL / scopes → Task 2. ✅
- README → Task 11. ✅
- Non-goals (no paging, lazy refresh, no eviction, no client_secret) honored across Tasks 4/5/9. ✅

**2. Placeholder scan:** No TBD/TODO; every code step shows full code. README step describes exact contents to include (acceptable — prose doc). ✅

**3. Type consistency:** `Tokens` fields (accessToken/refreshToken/expiry/email) consistent across Tasks 1/3/4/8. `TokenStore(backend:)` / `.load()` / `.save()` / `.clear()` consistent Tasks 3/4/8/9/10. `DriveClient(store:session:clientID:)`, `exportPDF(docID:)`, `metadata(docID:)` consistent Tasks 4/9. `PreviewCache(directory:)`, `cachedPDF(docID:modifiedTime:)`, `store(docID:modifiedTime:pdf:)`, `groupContainerURL()` consistent Tasks 5/9. `OAuthConfig.clientID(bundle:)` consistent Tasks 6/9/8. `PKCE.generate()`, `makeAuthURL(clientID:redirectURI:challenge:)`, `GoogleOAuthEndpoints` consistent Tasks 2/8. ✅

No gaps found.
