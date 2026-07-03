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
