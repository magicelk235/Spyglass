import XCTest
@testable import SpyglassKit

final class PreviewSettingsTests: XCTestCase {

    private var suite: String!

    override func setUp() {
        suite = "spyglass-settings-test-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testMissingSettingsLoadDefaults() {
        let s = PreviewSettings.load(groupID: suite)
        XCTAssertEqual(s, PreviewSettings())
        XCTAssertTrue(FormatGroup.allCases.allSatisfy(s.isEnabled))
    }

    func testRoundTrip() {
        var s = PreviewSettings()
        s.theme = .dark
        s.codeFontSize = 15
        s.disabledGroups = [.sqlite, .bundle]
        s.save(groupID: suite)
        let loaded = PreviewSettings.load(groupID: suite)
        XCTAssertEqual(loaded, s)
        XCTAssertFalse(loaded.isEnabled(.sqlite))
        XCTAssertTrue(loaded.isEnabled(.markdown))
    }

    func testCorruptStoredValueFallsBackToDefaults() {
        UserDefaults(suiteName: suite)!.set(Data("not json".utf8), forKey: "previewSettings")
        XCTAssertEqual(PreviewSettings.load(groupID: suite), PreviewSettings())
    }

    func testSettingsFromAnOlderVersionKeepKnownFields() {
        UserDefaults(suiteName: suite)!.set(Data(#"{"theme":"light"}"#.utf8), forKey: "previewSettings")
        let s = PreviewSettings.load(groupID: suite)
        XCTAssertEqual(s.theme, .light)
        XCTAssertEqual(s.codeFontSize, 12)
        XCTAssertEqual(s.disabledGroups, [])
    }

    func testFontSizeIsClamped() {
        var s = PreviewSettings()
        s.codeFontSize = 400
        s.save(groupID: suite)
        XCTAssertEqual(PreviewSettings.load(groupID: suite).codeFontSize, PreviewSettings.fontSizeRange.upperBound)
    }
}
