import XCTest
@testable import SpyglassKit

final class PreviewSettingsTests: XCTestCase {

    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("Spyglass/preview-settings.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spyglass-settings-test-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingSettingsLoadDefaults() {
        let s = PreviewSettings.load(from: file)
        XCTAssertEqual(s, PreviewSettings())
        XCTAssertTrue(FormatGroup.allCases.allSatisfy(s.isEnabled))
    }

    func testRoundTripCreatesTheFolder() throws {
        var s = PreviewSettings()
        s.theme = .dark
        s.codeFontSize = 15
        s.disabledGroups = [.sqlite, .bundle]
        try s.save(to: file)
        let loaded = PreviewSettings.load(from: file)
        XCTAssertEqual(loaded, s)
        XCTAssertFalse(loaded.isEnabled(.sqlite))
        XCTAssertTrue(loaded.isEnabled(.markdown))
    }

    func testCorruptFileFallsBackToDefaults() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(PreviewSettings.load(from: file), PreviewSettings())
    }

    func testSettingsFromAnOlderVersionKeepKnownFields() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"light"}"#.utf8).write(to: file)
        let s = PreviewSettings.load(from: file)
        XCTAssertEqual(s.theme, .light)
        XCTAssertEqual(s.codeFontSize, 12)
        XCTAssertEqual(s.disabledGroups, [])
    }

    func testFontSizeIsClamped() throws {
        var s = PreviewSettings()
        s.codeFontSize = 400
        try s.save(to: file)
        XCTAssertEqual(PreviewSettings.load(from: file).codeFontSize, PreviewSettings.fontSizeRange.upperBound)
    }

    /// The extension's sandbox exception is home-relative, so the default
    /// location must be under the real home folder, never a container.
    func testDefaultLocationIsUnderTheRealHomeFolder() {
        let path = PreviewSettings.defaultURL.path
        XCTAssertTrue(path.hasSuffix("/Library/Application Support/Spyglass/preview-settings.json"), path)
        XCTAssertFalse(path.contains("/Library/Containers/"), path)
    }
}
