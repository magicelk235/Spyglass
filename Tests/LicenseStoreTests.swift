import XCTest
@testable import SpyglassKit

final class LicenseStoreTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testValidLiveSalePasses() throws {
        // success=true, no refund flags → returns normally.
        XCTAssertNoThrow(try LicenseStore.verdict(
            status: 200, body: data(#"{"success":true,"purchase":{"refunded":false}}"#)))
    }

    func testValidSaleWithNoPurchaseBlockPasses() throws {
        XCTAssertNoThrow(try LicenseStore.verdict(
            status: 200, body: data(#"{"success":true}"#)))
    }

    func testUnknownKeyThrowsInvalid() {
        XCTAssertThrowsError(try LicenseStore.verdict(
            status: 404, body: data(#"{"success":false}"#))) {
            XCTAssertEqual($0 as? LicenseStore.LicenseError, .invalidKey)
        }
    }

    func testRefundedThrowsRefunded() {
        XCTAssertThrowsError(try LicenseStore.verdict(
            status: 200, body: data(#"{"success":true,"purchase":{"refunded":true}}"#))) {
            XCTAssertEqual($0 as? LicenseStore.LicenseError, .refunded)
        }
    }

    func testChargebackedThrowsRefunded() {
        XCTAssertThrowsError(try LicenseStore.verdict(
            status: 200, body: data(#"{"success":true,"purchase":{"chargebacked":true}}"#))) {
            XCTAssertEqual($0 as? LicenseStore.LicenseError, .refunded)
        }
    }

    func testGarbageBodyThrowsMalformed() {
        XCTAssertThrowsError(try LicenseStore.verdict(status: 200, body: data("not json"))) {
            XCTAssertEqual($0 as? LicenseStore.LicenseError, .malformed)
        }
    }

    func testFormEncodesProductIDReservedChars() {
        // The product id has '=' and '+'; both must be percent-encoded.
        let encoded = LicenseStore.form("YMTEmgQNPRDS27c2B_bflw==")
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
    }
}
