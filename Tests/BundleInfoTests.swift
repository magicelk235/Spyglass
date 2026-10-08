import XCTest
import zlib
@testable import SpyglassKit

final class BundleInfoTests: ArchiveTestCase {

    private func plistData(_ value: Any, format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
    }

    /// Architecture names as lipo reports them, for comparison.
    private func lipoArchitectures(_ binary: String) throws -> [String] {
        let output = try run("/usr/bin/lipo", ["-archs", binary])
        return String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// A self-signed certificate and key, for CMS signatures and xar.
    private func makeSigner() throws -> (certificate: URL, key: URL) {
        let certificate = dir.appendingPathComponent("signer.pem")
        let key = dir.appendingPathComponent("signer.key")
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                                     "-subj", "/CN=Spyglass Test Signer",
                                     "-keyout", key.path, "-out", certificate.path])
        return (certificate, key)
    }

    // MARK: - .app

    func testReadsTheSampleApp() throws {
        let info = try BundleInfo.readApp(at: fixture("Sample.app"))
        XCTAssertEqual(info.name, "Sample")
        XCTAssertEqual(info.bundleIdentifier, "com.example.sample")
        XCTAssertEqual(info.version, "2.1")
        XCTAssertEqual(info.build, "42")
        XCTAssertEqual(info.platform, "macOS")
        XCTAssertEqual(info.minimumSystem, "14.0")
        XCTAssertNil(info.category)
        XCTAssertEqual(info.architectures, [])
        XCTAssertEqual(info.signing, .unsigned)
    }

    func testAdHocSignedAppShowsItsSignatureEntitlementsAndArchitectures() throws {
        let app = dir.appendingPathComponent("Tiny.app")
        try write("Tiny.app/Contents/Info.plist", try plistData([
            "CFBundleExecutable": "tiny",
            "CFBundleIdentifier": "com.example.tiny",
            "CFBundleName": "Tiny",
            "LSApplicationCategoryType": "public.app-category.developer-tools",
            "NSHumanReadableCopyright": "© 2026 Example",
        ]))
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/tiny").path)
        let entitlements = try write("tiny.entitlements", try plistData([
            "com.apple.security.app-sandbox": true,
            "com.apple.security.temporary-exception.files.absolute-path.read-only": ["/a/", "/b/"],
        ]))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entitlements.path, app.path])

        let info = try BundleInfo.readApp(at: app)
        XCTAssertEqual(info.category, "Developer Tools")
        XCTAssertEqual(info.copyright, "© 2026 Example")
        XCTAssertEqual(info.architectures, try lipoArchitectures("/usr/bin/true"))
        guard case .signed(let signature) = info.signing else { return XCTFail("\(String(describing: info.signing))") }
        XCTAssertTrue(signature.isAdHoc)
        XCTAssertEqual(signature.identifier, "com.example.tiny")
        XCTAssertEqual(signature.authorities, [])
        XCTAssertNil(signature.teamIdentifier)
        XCTAssertEqual(signature.entitlements, [
            PropertyRow(key: "com.apple.security.app-sandbox", value: "true"),
            PropertyRow(key: "com.apple.security.temporary-exception.files.absolute-path.read-only", value: "/a/\n/b/"),
        ])
    }

    func testReadsAppleSigningOnASystemApp() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: calculator.path))
        let info = try BundleInfo.readApp(at: calculator)
        XCTAssertEqual(info.bundleIdentifier, "com.apple.calculator")
        XCTAssertEqual(info.architectures, try lipoArchitectures(calculator.appendingPathComponent("Contents/MacOS/Calculator").path))
        guard case .signed(let signature) = info.signing else { return XCTFail("\(String(describing: info.signing))") }
        XCTAssertEqual(signature.identifier, "com.apple.calculator")
        XCTAssertFalse(signature.isAdHoc)
        XCTAssertEqual(signature.authorities.last, "Apple Root CA")
        XCTAssertGreaterThan(signature.authorities.count, 1)
        XCTAssertTrue(signature.entitlements.contains(PropertyRow(key: "com.apple.security.app-sandbox", value: "true")))
    }

    func testFilesThatArentBundlesThrow() throws {
        XCTAssertThrowsError(try BundleInfo.readApp(at: try write("Fake.app", "not a folder")))
    }

    func testArchitecturesFromMachOHeaders() {
        var fat: [UInt8] = []
        fat.be32(0xCAFE_BABE); fat.be32(2)
        fat.be32(0x0100_0007); fat.be32(3); fat.be32(0x4000); fat.be32(100); fat.be32(14)
        fat.be32(0x0100_000C); fat.be32(0); fat.be32(0x8000); fat.be32(100); fat.be32(14)
        XCTAssertEqual(MachOHeader.architectures(in: fat), ["x86_64", "arm64"])

        var thin: [UInt8] = []
        thin.le32(0xFEED_FACF); thin.le32(0x0100_000C); thin.le32(0)
        XCTAssertEqual(MachOHeader.architectures(in: thin), ["arm64"])

        // A Java class file shares the fat magic; its version isn't a slice count.
        var java: [UInt8] = []
        java.be32(0xCAFE_BABE); java.be32(0x0000_0034)
        XCTAssertNil(MachOHeader.architectures(in: java))
        XCTAssertNil(MachOHeader.architectures(in: Array("#!/bin/sh\n".utf8)))
        XCTAssertNil(MachOHeader.architectures(in: Array(fat.prefix(20))))
    }

    // MARK: - .ipa

    func testReadsTheSampleIPA() throws {
        let info = try BundleInfo.readIPA(at: fixture("Sample.ipa"))
        XCTAssertEqual(info.name, "SampleiOS")
        XCTAssertEqual(info.bundleIdentifier, "com.example.ios")
        XCTAssertEqual(info.version, "3.0")
        XCTAssertEqual(info.build, "7")
        XCTAssertEqual(info.platform, "iOS")
        XCTAssertEqual(info.minimumSystem, "17.0")
        XCTAssertNil(info.profile)
        XCTAssertNil(info.signing)
    }

    func testReadsAnIPAsProfileExecutableAndIcon() throws {
        let signer = try makeSigner()
        let profile = try write("profile.plist", try plistData([
            "Name": "Tiny Development",
            "AppIDName": "Tiny",
            "TeamName": "Example Team",
            "TeamIdentifier": ["ABCDE12345"],
            "CreationDate": Date(timeIntervalSince1970: 1_577_836_800),
            "ExpirationDate": Date(timeIntervalSince1970: 1_609_459_200),
            "ProvisionedDevices": ["00008030-0001", "00008030-0002", "00008030-0003"],
            "Platform": ["iOS"],
            "Entitlements": ["get-task-allow": true, "application-identifier": "ABCDE12345.com.example.tiny"],
        ]))
        let app = "Payload/Tiny.app"
        try write("\(app)/Info.plist", try plistData([
            "CFBundleExecutable": "Tiny",
            "CFBundleIdentifier": "com.example.tiny",
            "CFBundleDisplayName": "Tiny Display",
            "UIDeviceFamily": [1, 2],
            "CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"]]],
        ], format: .binary))
        try run("/usr/bin/openssl", ["smime", "-sign", "-in", profile.path, "-signer", signer.certificate.path,
                                     "-inkey", signer.key.path, "-outform", "der", "-nodetach", "-binary",
                                     "-out", dir.appendingPathComponent("\(app)/embedded.mobileprovision").path])
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: dir.appendingPathComponent("\(app)/Tiny").path)
        let largeIcon = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 0x22, count: 400))
        try write("\(app)/AppIcon60x60@2x.png", largeIcon)
        try write("\(app)/AppIcon60x60.png", Data([0x89, 0x50, 0x4E, 0x47, 0x11]))
        try run("/usr/bin/zip", ["-q", "-r", "Tiny.ipa", "Payload"])

        let info = try BundleInfo.readIPA(at: dir.appendingPathComponent("Tiny.ipa"))
        XCTAssertEqual(info.name, "Tiny Display")
        XCTAssertEqual(info.devices, ["iPhone", "iPad"])
        XCTAssertEqual(info.architectures, try lipoArchitectures("/usr/bin/true"))
        XCTAssertEqual(info.iconData, largeIcon)
        let decoded = try XCTUnwrap(info.profile)
        XCTAssertEqual(decoded.name, "Tiny Development")
        XCTAssertEqual(decoded.appIDName, "Tiny")
        XCTAssertEqual(decoded.teamName, "Example Team")
        XCTAssertEqual(decoded.teamIdentifiers, ["ABCDE12345"])
        XCTAssertEqual(decoded.expires, Date(timeIntervalSince1970: 1_609_459_200))
        XCTAssertTrue(decoded.isExpired())
        XCTAssertFalse(decoded.isExpired(at: Date(timeIntervalSince1970: 1_600_000_000)))
        XCTAssertEqual(decoded.deviceCount, 3)
        XCTAssertEqual(decoded.distribution, .development)
        XCTAssertEqual(decoded.entitlements, [
            PropertyRow(key: "application-identifier", value: "ABCDE12345.com.example.tiny"),
            PropertyRow(key: "get-task-allow", value: "true"),
        ])
    }

    func testProfileDistributionKinds() throws {
        func kind(_ plist: [String: Any]) throws -> ProvisioningProfile.Distribution {
            try ProvisioningProfile.decode(try plistData(plist)).distribution
        }
        XCTAssertEqual(try kind(["ProvisionsAllDevices": true]), .enterprise)
        XCTAssertEqual(try kind(["ProvisionedDevices": ["a"]]), .adHoc)
        XCTAssertEqual(try kind(["ProvisionedDevices": ["a"], "Entitlements": ["get-task-allow": true]]), .development)
        XCTAssertEqual(try kind(["Name": "Store"]), .appStore)
        XCTAssertThrowsError(try ProvisioningProfile.decode(Data("not a profile".utf8)))
        XCTAssertThrowsError(try ProvisioningProfile.decode(Data()))
    }

    func testIPAWithoutAnAppThrows() throws {
        try write("Payload/readme.txt", "no app here")
        try run("/usr/bin/zip", ["-q", "-r", "Empty.ipa", "Payload"])
        XCTAssertThrowsError(try BundleInfo.readIPA(at: dir.appendingPathComponent("Empty.ipa")))
    }

    // MARK: - .pkg

    func testReadsTheSamplePackage() throws {
        let info = try PackageInfo.read(at: fixture("Sample.pkg"))
        XCTAssertEqual(info.identifier, "com.example.sample.pkg")
        XCTAssertEqual(info.version, "1.2")
        XCTAssertEqual(info.installLocation, "/tmp/sample")
        XCTAssertEqual(info.payloadFileCount, 2)
        XCTAssertEqual(info.installedSize, 1024)
        XCTAssertEqual(info.payloadArchivedSize, 114)
        let sizes = Dictionary(uniqueKeysWithValues: info.files.entries.map { ($0.path, $0.size) })
        XCTAssertEqual(sizes, ["Bom": 57230, "Payload": 114, "PackageInfo": 480])
        XCTAssertEqual(info.signers, [])
    }

    /// A product archive with a signature, a stored Distribution, and a
    /// zlib-compressed component PackageInfo.
    func testReadsAProductArchive() throws {
        let signer = try makeSigner()
        let pem = try String(contentsOf: signer.certificate, encoding: .utf8)
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined(separator: "\n")

        let distribution = Array("""
            <?xml version="1.0" encoding="utf-8"?>
            <installer-gui-script minSpecVersion="1">
                <title>Tiny Installer</title>
                <product id="com.example.tiny.product" version="5.0"/>
                <options customize="never" hostArchitectures="arm64,x86_64"/>
                <allowed-os-versions><os-version min="13.0"/></allowed-os-versions>
                <choice id="default"><pkg-ref id="com.example.tiny"/></choice>
                <pkg-ref id="com.example.tiny" version="5.0.1" installKBytes="2048">#Tiny.pkg</pkg-ref>
                <pkg-ref id="com.example.helper" version="1.0" installKBytes="16">#Helper.pkg</pkg-ref>
            </installer-gui-script>
            """.utf8)
        let packageInfo = Array("""
            <pkg-info identifier="com.example.tiny" version="5.0.1" install-location="/Applications">
                <payload numberOfFiles="12" installKBytes="2048"/>
            </pkg-info>
            """.utf8)
        let packedInfo = try zlibCompress(packageInfo)
        let payload = [UInt8](repeating: 0x50, count: 1000)
        let toc = """
            <?xml version="1.0" encoding="UTF-8"?>
            <xar><toc>
            <creation-time>2026-10-08T07:36:17</creation-time>
            <signature style="RSA"><offset>0</offset><size>256</size>
            <KeyInfo xmlns="http://www.w3.org/2000/09/xmldsig#"><X509Data><X509Certificate>\(base64)</X509Certificate></X509Data></KeyInfo>
            </signature>
            <file id="1"><name>Distribution</name><type>file</type>
            <data><offset>0</offset><length>\(distribution.count)</length><size>\(distribution.count)</size>
            <encoding style="application/octet-stream"/></data></file>
            <file id="2"><name>Tiny.pkg</name><type>directory</type>
            <file id="3"><name>PackageInfo</name><type>file</type>
            <data><offset>\(distribution.count)</offset><length>\(packedInfo.count)</length><size>\(packageInfo.count)</size>
            <encoding style="application/x-gzip"/></data></file>
            <file id="4"><name>Payload</name><type>file</type>
            <data><offset>\(distribution.count + packedInfo.count)</offset><length>1000</length><size>4000</size>
            <encoding style="application/octet-stream"/></data></file>
            </file>
            </toc></xar>
            """
        let packedTOC = try zlibCompress(Array(toc.utf8))
        var xar: [UInt8] = Array("xar!".utf8)
        xar.be16(28); xar.be16(1); xar.be64(UInt64(packedTOC.count)); xar.be64(UInt64(toc.utf8.count)); xar.be32(1)
        xar += packedTOC + distribution + packedInfo + payload

        let info = try PackageInfo.read(at: try write("Tiny.pkg", Data(xar)))
        XCTAssertEqual(info.title, "Tiny Installer")
        XCTAssertEqual(info.identifier, "com.example.tiny.product")
        XCTAssertEqual(info.version, "5.0")
        XCTAssertEqual(info.architectures, ["arm64", "x86_64"])
        XCTAssertEqual(info.minimumSystem, "13.0")
        XCTAssertEqual(info.components, [
            .init(identifier: "com.example.tiny", version: "5.0.1", installedSize: 2048 * 1024),
            .init(identifier: "com.example.helper", version: "1.0", installedSize: 16 * 1024),
        ])
        XCTAssertEqual(info.installedSize, 2064 * 1024)
        XCTAssertEqual(info.installLocation, "/Applications")
        XCTAssertEqual(info.payloadFileCount, 12)
        XCTAssertEqual(info.payloadArchivedSize, 1000)
        XCTAssertEqual(info.signers, ["Spyglass Test Signer"])
        XCTAssertEqual(info.created, Date(timeIntervalSince1970: 1_791_444_977))
        XCTAssertEqual(info.files.entries.map(\.path), ["Distribution", "Tiny.pkg", "Tiny.pkg/PackageInfo", "Tiny.pkg/Payload"])
        XCTAssertEqual(info.files.entries.map(\.kind), [.file, .directory, .file, .file])
    }

    func testFilesThatArentPackagesThrow() throws {
        XCTAssertThrowsError(try PackageInfo.read(at: try write("garbage.pkg", repetitiveText(500)))) { error in
            XCTAssertEqual(error as? ArchiveError, .unrecognized("Not a flat installer package"))
        }
        let sample = try Data(contentsOf: fixture("Sample.pkg"))
        XCTAssertThrowsError(try PackageInfo.read(at: try write("cut.pkg", sample.prefix(200))))
    }

    private func zlibCompress(_ bytes: [UInt8]) throws -> [UInt8] {
        var length = compressBound(uLong(bytes.count))
        var output = [UInt8](repeating: 0, count: Int(length))
        let status = compress(&output, &length, bytes, uLong(bytes.count))
        XCTAssertEqual(status, Z_OK)
        return Array(output.prefix(Int(length)))
    }

    // MARK: - .dmg

    func testReadsTheSampleDiskImage() throws {
        let info = try DiskImageInfo.read(at: fixture("Sample.dmg"))
        XCTAssertEqual(info.version, 4)
        XCTAssertEqual(info.format, "UDZO")
        XCTAssertEqual(info.compressedSize, 8306)
        XCTAssertEqual(info.expandedSize, 20546 * 512)
        XCTAssertEqual(info.partitions, ["disk image (APFS)"])
        XCTAssertFalse(info.isEncrypted)
        XCTAssertFalse(info.isSigned)
        XCTAssertNil(info.signing)
    }

    func testSignedDiskImageShowsItsSignature() throws {
        let copy = dir.appendingPathComponent("Signed.dmg")
        try FileManager.default.copyItem(at: fixture("Sample.dmg"), to: copy)
        try run("/usr/bin/codesign", ["--sign", "-", copy.path])
        let info = try DiskImageInfo.read(at: copy)
        XCTAssertTrue(info.isSigned)
        guard case .signed(let signature) = info.signing else { return XCTFail("\(String(describing: info.signing))") }
        XCTAssertTrue(signature.isAdHoc)
        XCTAssertEqual(info.format, "UDZO")
    }

    func testEncryptedDiskImageSaysSoAndNothingElse() throws {
        let url = try write("Secret.dmg", Data(Array("encrcdsa".utf8) + Array(repeating: 0x33, count: 4096)))
        let info = try DiskImageInfo.read(at: url)
        XCTAssertTrue(info.isEncrypted)
        XCTAssertNil(info.format)
        XCTAssertNil(info.expandedSize)
    }

    func testDiskImageWithoutATrailerThrows() throws {
        let sample = try Data(contentsOf: fixture("Sample.dmg"))
        XCTAssertThrowsError(try DiskImageInfo.read(at: try write("cut.dmg", sample.dropLast(512)))) { error in
            XCTAssertEqual(error as? ArchiveError, .unrecognized("Not a UDIF disk image"))
        }
        XCTAssertThrowsError(try DiskImageInfo.read(at: try write("tiny.dmg", Data([1, 2, 3]))))
    }

    func testPartitionNamesDropTheSchemeDecoration() {
        XCTAssertEqual(DiskImageInfo.partitionName("disk image (Apple_HFS : 2)"), "disk image (HFS)")
        XCTAssertEqual(DiskImageInfo.partitionName(" (Apple_Free : 3)"), "Free")
        XCTAssertEqual(DiskImageInfo.partitionName("Untitled"), "Untitled")
    }
}
