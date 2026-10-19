import XCTest
@testable import SpyglassKit

final class AppGroupTests: XCTestCase {

    private var suites: [String] = []
    private var dirs: [URL] = []

    private func suite() -> UserDefaults {
        let name = "spyglass-group-test-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("spyglass-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    override func tearDown() {
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// The identifier the code opens must be the one every target is
    /// entitled to, or the extensions silently lose the license and cache.
    func testAllEntitlementsUseTheSharedIdentifier() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["App/App.entitlements", "Preview/Preview.entitlements", "Thumbnail/Thumbnail.entitlements"] {
            let plist = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent(path)))
            let groups = try XCTUnwrap(plist["com.apple.security.application-groups"] as? [String], path)
            XCTAssertTrue(groups.contains(AppGroup.identifier), path)
        }
        XCTAssertTrue(AppGroup.identifier.hasPrefix("V8K8L3ZSD5."))
    }

    /// Only a plan that includes Drive may see cached Drive PDFs: not the
    /// trial, not Pro alone.
    func testDriveCacheShowsPDFsOnlyWithDriveAccess() throws {
        let drive = suite(), pro = suite(), trial = suite()
        drive.set("K", forKey: "licenseKey"); drive.set("drive", forKey: "licensePlan"); drive.set(true, forKey: "membershipActive")
        pro.set("K", forKey: "licenseKey"); pro.set("pro", forKey: "licensePlan")
        trial.set(Date(), forKey: "trialStartedAt")
        let container = try dir()
        try PreviewCache(directory: container).store(docID: "DOC", modifiedTime: "t", pdf: Data("pdf".utf8))

        XCTAssertEqual(DriveCache.licensedPDF(docID: "DOC", license: LicenseStore(defaults: drive), container: container),
                       Data("pdf".utf8))
        XCTAssertNil(DriveCache.licensedPDF(docID: "DOC", license: LicenseStore(defaults: pro), container: container))
        XCTAssertNil(DriveCache.licensedPDF(docID: "DOC", license: LicenseStore(defaults: trial), container: container))
        XCTAssertNil(DriveCache.licensedPDF(docID: "OTHER", license: LicenseStore(defaults: drive), container: container))
    }

    func testMigrationCopiesLicenseAndMovesPreviews() throws {
        let legacy = suite(), current = suite()
        legacy.set("KEY-1", forKey: "licenseKey")
        legacy.set(true, forKey: "isPro")
        let old = try dir(), new = try dir()
        let oldPreviews = old.appendingPathComponent("previews")
        try FileManager.default.createDirectory(at: oldPreviews, withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: oldPreviews.appendingPathComponent("a.pdf"))

        LegacyGroupMigration.run(legacyDefaults: legacy, legacyContainer: old, defaults: current, container: new)

        XCTAssertEqual(current.string(forKey: "licenseKey"), "KEY-1")
        XCTAssertTrue(current.bool(forKey: "isPro"))
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("previews/a.pdf")), Data("pdf".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPreviews.appendingPathComponent("a.pdf").path))
    }

    func testMigrationNeverOverwritesCurrentData() throws {
        let legacy = suite(), current = suite()
        legacy.set("OLD", forKey: "licenseKey")
        legacy.set(true, forKey: "isPro")
        current.set("NEW", forKey: "licenseKey")
        current.set(false, forKey: "isPro")
        let old = try dir(), new = try dir()
        for (base, body) in [(old, "old"), (new, "new")] {
            let p = base.appendingPathComponent("previews")
            try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: p.appendingPathComponent("a.pdf"))
        }

        LegacyGroupMigration.run(legacyDefaults: legacy, legacyContainer: old, defaults: current, container: new)

        XCTAssertEqual(current.string(forKey: "licenseKey"), "NEW")
        XCTAssertFalse(current.bool(forKey: "isPro"))
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("previews/a.pdf")), Data("new".utf8))
    }

    func testMigrationWithNothingLegacyIsANoOp() throws {
        let current = suite()
        LegacyGroupMigration.run(legacyDefaults: suite(), legacyContainer: try dir(), defaults: current, container: try dir())
        XCTAssertNil(current.string(forKey: "licenseKey"))
    }
}
