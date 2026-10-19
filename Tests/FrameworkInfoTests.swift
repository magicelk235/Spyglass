import XCTest
@testable import SpyglassKit

final class FrameworkInfoTests: ArchiveTestCase {

    private func plist(_ values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    private func compileLibrary(to path: String, installName: String) throws {
        let source = try write("src/tiny.c", "int tiny(void) { return 1; }\n")
        let output = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run("/usr/bin/clang", ["-dynamiclib", "-arch", "arm64", "-install_name", installName,
                                   "-current_version", "2.1", "-compatibility_version", "1.0",
                                   "-mmacosx-version-min=13.0", "-o", output.path, source.path])
    }

    func testReadsASystemFrameworkWhoseBinaryIsInTheSharedCache() throws {
        let url = URL(fileURLWithPath: "/System/Library/Frameworks/Accelerate.framework")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        let info = try BundleInfo.readFramework(at: url)
        XCTAssertEqual(info.bundle.bundleIdentifier, "com.apple.Accelerate")
        XCTAssertEqual(info.bundle.platform, "macOS")
        XCTAssertNotNil(info.bundle.version)
        XCTAssertEqual(info.versions, ["A"])
        XCTAssertEqual(info.currentVersion, "A")
        XCTAssertTrue(info.frameworks.contains("vecLib"))
        switch info.binary {
        case .missing(let name):
            XCTAssertEqual(name, "Accelerate")
        case .machO(let binary):
            // Older systems kept the binary on disk.
            XCTAssertEqual(binary.slices.first?.identity?.path,
                           "/System/Library/Frameworks/Accelerate.framework/Versions/A/Accelerate")
        case .unreadable(let reason):
            XCTFail(reason)
        }
    }

    func testReadsAVersionedFrameworkWithItsBinaryAndSignature() throws {
        let framework = dir.appendingPathComponent("Tiny.framework")
        try compileLibrary(to: "Tiny.framework/Versions/A/Tiny", installName: "@rpath/Tiny.framework/Versions/A/Tiny")
        let values: [String: Any] = [
            "CFBundleIdentifier": "com.example.tiny", "CFBundleExecutable": "Tiny", "CFBundleName": "Tiny Kit",
            "CFBundleShortVersionString": "2.1", "CFBundleVersion": "210", "CFBundlePackageType": "FMWK",
            "CFBundleSupportedPlatforms": ["MacOSX"], "NSHumanReadableCopyright": "© Example",
        ]
        try write("Tiny.framework/Versions/A/Resources/Info.plist", try plist(values))
        try write("Tiny.framework/Versions/B/Resources/Info.plist", try plist(["CFBundleIdentifier": "old"]))
        let manager = FileManager.default
        try manager.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try manager.createSymbolicLink(atPath: framework.appendingPathComponent("Tiny").path,
                                       withDestinationPath: "Versions/Current/Tiny")
        try manager.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path,
                                       withDestinationPath: "Versions/Current/Resources")
        try run("/usr/bin/codesign", ["--force", "--sign", "-", framework.path])
        // Added after signing: codesign refuses unsigned nested code. The
        // signature's details still read; only its seal is broken.
        try manager.createDirectory(at: framework.appendingPathComponent("Versions/A/Frameworks/Inner.framework"),
                                    withIntermediateDirectories: true)

        let info = try BundleInfo.readFramework(at: framework)
        XCTAssertEqual(info.bundle.name, "Tiny Kit")
        XCTAssertEqual(info.bundle.bundleIdentifier, "com.example.tiny")
        XCTAssertEqual(info.bundle.version, "2.1")
        XCTAssertEqual(info.bundle.build, "210")
        XCTAssertEqual(info.bundle.copyright, "© Example")
        XCTAssertEqual(info.bundle.platform, "macOS")
        XCTAssertEqual(info.bundle.architectures, ["arm64"])
        XCTAssertEqual(info.versions, ["A", "B"])
        XCTAssertEqual(info.currentVersion, "A")
        XCTAssertEqual(info.frameworks, ["Inner"])
        guard case .machO(let binary) = info.binary else { return XCTFail("\(info.binary)") }
        let slice = try XCTUnwrap(binary.slices.first)
        XCTAssertEqual(slice.fileType, .dylib)
        XCTAssertEqual(slice.identity?.path, "@rpath/Tiny.framework/Versions/A/Tiny")
        XCTAssertEqual(slice.identity?.currentVersion, "2.1.0")
        XCTAssertEqual(slice.buildVersions.first?.minimumOS, "13.0")
        guard case .signed(let signature)? = info.bundle.signing else {
            return XCTFail("\(String(describing: info.bundle.signing))")
        }
        XCTAssertTrue(signature.isAdHoc)
        XCTAssertFalse(signature.isLinkerSigned)
        XCTAssertEqual(signature.identifier, "com.example.tiny")
    }

    func testShallowFrameworkKeepsEverythingAtTheTop() throws {
        try compileLibrary(to: "Mobile.framework/Mobile", installName: "@rpath/Mobile.framework/Mobile")
        try write("Mobile.framework/Info.plist", try plist([
            "CFBundleIdentifier": "com.example.mobile", "CFBundleExecutable": "Mobile",
            "CFBundleSupportedPlatforms": ["iPhoneOS"], "MinimumOSVersion": "16.0",
        ]))
        let info = try BundleInfo.readFramework(at: dir.appendingPathComponent("Mobile.framework"))
        XCTAssertEqual(info.bundle.platform, "iOS")
        XCTAssertEqual(info.bundle.minimumSystem, "16.0")
        XCTAssertEqual(info.versions, [])
        XCTAssertNil(info.currentVersion)
        guard case .machO(let binary) = info.binary else { return XCTFail("\(info.binary)") }
        XCTAssertEqual(binary.slices.first?.identity?.path, "@rpath/Mobile.framework/Mobile")
    }

    func testMissingOrDamagedBinaries() throws {
        try write("Empty.framework/Resources/Info.plist", try plist(["CFBundleExecutable": "Gone"]))
        let empty = try BundleInfo.readFramework(at: dir.appendingPathComponent("Empty.framework"))
        guard case .missing(let name) = empty.binary else { return XCTFail("\(empty.binary)") }
        XCTAssertEqual(name, "Gone")
        XCTAssertEqual(empty.bundle.name, "Empty")

        // No plist: the binary is named after the folder.
        try write("Junk.framework/Junk", "not a binary")
        let junk = try BundleInfo.readFramework(at: dir.appendingPathComponent("Junk.framework"))
        guard case .unreadable = junk.binary else { return XCTFail("\(junk.binary)") }

        XCTAssertThrowsError(try BundleInfo.readFramework(at: try write("File.framework", "a file, not a bundle")))
    }
}
