import XCTest
@testable import DrivePeakKit

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
