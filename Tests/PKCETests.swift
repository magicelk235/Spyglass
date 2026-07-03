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
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        XCTAssertTrue(pkce.verifier.unicodeScalars.allSatisfy { unreserved.contains($0) })
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
        XCTAssertTrue(s.contains("prompt=consent"))
        // scope is URL-encoded; check one scope fragment survives
        XCTAssertTrue(s.contains("drive.readonly"))
    }
}
