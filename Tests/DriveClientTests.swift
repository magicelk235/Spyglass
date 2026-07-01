import XCTest
@testable import DrivePeakKit

/// URLProtocol stub: maps a URL substring → (status, body). Records requests.
/// firstCallStatus: if set, returned on the FIRST match; subsequent matches use `status`.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [(match: String, status: Int, body: Data, firstCallStatus: Int?)] = []
    nonisolated(unsafe) static var requestedURLs: [String] = []
    nonisolated(unsafe) static var callCounts: [String: Int] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        let urlString = request.url?.absoluteString ?? ""
        Self.requestedURLs.append(urlString)
        guard let route = Self.routes.first(where: { urlString.contains($0.match) }) else {
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let count = Self.callCounts[route.match, default: 0]
        Self.callCounts[route.match] = count + 1
        let status: Int
        if count == 0, let first = route.firstCallStatus {
            status = first
        } else {
            status = route.status
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
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

    private func validToken() -> Tokens {
        Tokens(accessToken: "AT", refreshToken: "RT", expiry: .distantFuture, email: nil)
    }

    override func setUp() {
        StubURLProtocol.routes = []
        StubURLProtocol.requestedURLs = []
        StubURLProtocol.callCounts = [:]
    }

    func testExportPDFReturnsBody() async throws {
        StubURLProtocol.routes = [
            (match: "/export", status: 200, body: Data("PDFBYTES".utf8), firstCallStatus: nil),
        ]
        let c = makeClient(tokens: validToken())
        let data = try await c.exportPDF(docID: "DOC1")
        XCTAssertEqual(String(data: data, encoding: .utf8), "PDFBYTES")
        XCTAssertTrue(StubURLProtocol.requestedURLs.contains { $0.contains("files/DOC1/export") })
        XCTAssertTrue(StubURLProtocol.requestedURLs.contains { $0.contains("mimeType=application/pdf") })
    }

    /// FIX 1: genuinely drives the reactive 401 branch (token NOT expired; first /export → 401; refresh; retry → 200).
    func test401TriggersRefreshThenRetrySucceeds() async throws {
        StubURLProtocol.routes = [
            (match: "/token",  status: 200, body: Data(#"{"access_token":"NEW","expires_in":3600}"#.utf8), firstCallStatus: nil),
            (match: "/export", status: 200, body: Data("OK".utf8), firstCallStatus: 401),
        ]
        // FUTURE expiry → pre-check does NOT refresh; first /export returns 401 → reactive refresh fires
        let c = makeClient(tokens: Tokens(accessToken: "OLD", refreshToken: "RT",
                                          expiry: .distantFuture, email: nil))
        let data = try await c.exportPDF(docID: "DOC1")
        XCTAssertEqual(String(data: data, encoding: .utf8), "OK")
        // /token was hit (reactive refresh fired)
        XCTAssertTrue(StubURLProtocol.requestedURLs.contains { $0.contains("/token") })
        // /export was requested exactly twice (first 401, then retry 200)
        XCTAssertEqual(StubURLProtocol.callCounts["/export"], 2)
    }

    func testMetadataDecodes() async throws {
        StubURLProtocol.routes = [
            (match: "fields=", status: 200, body: Data(#"{"name":"My Doc","modifiedTime":"2026-07-01T00:00:00Z"}"#.utf8), firstCallStatus: nil),
        ]
        let c = makeClient(tokens: validToken())
        let m = try await c.metadata(docID: "DOC1")
        XCTAssertEqual(m, DriveMetadata(name: "My Doc", modifiedTime: "2026-07-01T00:00:00Z"))
    }

    // MARK: - FIX 4: branch coverage tests

    /// Both /export calls return 401; must throw http(401) without looping.
    func testRetryAlso401GivesUp() async throws {
        StubURLProtocol.routes = [
            (match: "/token",  status: 200, body: Data(#"{"access_token":"NEW","expires_in":3600}"#.utf8), firstCallStatus: nil),
            (match: "/export", status: 401, body: Data(), firstCallStatus: 401),
        ]
        let c = makeClient(tokens: validToken())
        do {
            _ = try await c.exportPDF(docID: "DOC1")
            XCTFail("expected throw")
        } catch let e as DriveError {
            XCTAssertEqual(e, .http(401))
        }
        // Refresh must have fired exactly once
        XCTAssertEqual(StubURLProtocol.callCounts["/token"], 1)
        // Export tried twice
        XCTAssertEqual(StubURLProtocol.callCounts["/export"], 2)
    }

    /// Expired token + /token returns non-200 → refreshFailed.
    func testRefreshFailureThrows() async throws {
        StubURLProtocol.routes = [
            (match: "/token", status: 500, body: Data(), firstCallStatus: nil),
        ]
        let c = makeClient(tokens: Tokens(accessToken: "OLD", refreshToken: "RT",
                                          expiry: .distantPast, email: nil))
        do {
            _ = try await c.exportPDF(docID: "DOC1")
            XCTFail("expected throw")
        } catch let e as DriveError {
            XCTAssertEqual(e, .refreshFailed)
        }
    }

    /// Metadata route returns 200 with non-JSON → decode error.
    func testMetadataBadJSONThrowsDecode() async throws {
        StubURLProtocol.routes = [
            (match: "fields=", status: 200, body: Data("not-json".utf8), firstCallStatus: nil),
        ]
        let c = makeClient(tokens: validToken())
        do {
            _ = try await c.metadata(docID: "DOC1")
            XCTFail("expected throw")
        } catch let e as DriveError {
            XCTAssertEqual(e, .decode)
        }
    }

    /// /export returns 500 → http(500) thrown, no refresh.
    func testNon401HTTPErrorThrows() async throws {
        StubURLProtocol.routes = [
            (match: "/export", status: 500, body: Data(), firstCallStatus: nil),
        ]
        let c = makeClient(tokens: validToken())
        do {
            _ = try await c.exportPDF(docID: "DOC1")
            XCTFail("expected throw")
        } catch let e as DriveError {
            XCTAssertEqual(e, .http(500))
        }
        // No refresh should have been attempted
        XCTAssertNil(StubURLProtocol.callCounts["/token"])
    }
}
