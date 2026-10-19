import XCTest
@testable import SpyglassKit

final class PackageManifestTests: ArchiveTestCase {

    /// A zip of stored members, in order.
    private func zip(_ members: [(String, String)]) -> Data {
        var builder = ZipBuilder()
        builder.members = members.map { ZipBuilder.Member(name: Array($0.0.utf8), data: Array($0.1.utf8)) }
        return builder.build()
    }

    private func manifest(_ name: String, _ members: [(String, String)]) throws -> PackageManifest? {
        try manifest(of: try write(name, zip(members)))
    }

    private func manifest(of url: URL) throws -> PackageManifest? {
        let type = try XCTUnwrap(PackageType(filename: url.lastPathComponent))
        return try ArchiveReader.listPackage(url, type: type).manifest
    }

    private func fields(_ manifest: PackageManifest?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (manifest?.fields ?? []).map { ($0.label, $0.value) })
    }

    // MARK: - Java

    func testJarManifestMainSection() throws {
        let text = "Manifest-Version: 1.0\r\n"
            + "Created-By: 17.0.8 (Eclipse Adoptium)\r\n"
            + "Main-Class: com.example.cli.Main\r\n"
            + "Implementation-Title: Example CLI\r\n"
            + "Implementation-Version: 3.1.4\r\n"
            + "Automatic-Module-Name: com.example.cli.with.a.name.long.enough.to.wrap.past.seventy-two.byt\r\n"
            + " es\r\n"
            + "\r\n"
            + "Name: com/example/cli/\r\n"
            + "Implementation-Title: Section title, not the jar's\r\n"
        let jar = try manifest("tool.jar", [("META-INF/MANIFEST.MF", text), ("com/example/cli/Main.class", "x")])
        XCTAssertEqual(jar?.kind, "Java archive")
        XCTAssertEqual(jar?.source, "META-INF/MANIFEST.MF")
        XCTAssertEqual(jar?.fields.map(\.label), ["Main class", "Title", "Version", "Module name", "Created by"])
        XCTAssertEqual(fields(jar), [
            "Main class": "com.example.cli.Main",
            "Title": "Example CLI",
            "Version": "3.1.4",
            "Module name": "com.example.cli.with.a.name.long.enough.to.wrap.past.seventy-two.bytes",
            "Created by": "17.0.8 (Eclipse Adoptium)",
        ])
        XCTAssertEqual(try manifest("app.war", [("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\n")])?.kind,
                       "Java web application")
        XCTAssertEqual(try manifest("suite.ear", [("meta-inf/manifest.mf", "Main-Class: A\n")])?.fields.first?.value, "A")
        XCTAssertNil(try manifest("bare.jar", [("A.class", "x")]))
    }

    func testJarManifestLineEndingsAndJunk() {
        let attributes = PackageManifest.jarManifestAttributes("\n\nMain-Class: A\rjunk line\nImplementation-Version:2\n x\n\nName: B\n")
        XCTAssertEqual(attributes.map(\.key), ["Main-Class", "Implementation-Version"])
        XCTAssertEqual(attributes.map(\.value), ["A", "2x"])
    }

    // MARK: - Python

    func testWheelMetadataAndTags() throws {
        let metadata = """
            Metadata-Version: 2.1
            Name: example-pkg
            Version: 1.0.2
            Summary: A small example package
            Description: first line
                    continued line
            Requires-Python: >=3.9
            Requires-Dist: requests (>=2)
            Requires-Dist: rich
            Requires-Dist: pytest ; extra == "test"
            Requires-Dist: black; extra=='dev'

            # Long description
            Name: not-a-header
            """
        let wheel = "Wheel-Version: 1.0\nGenerator: bdist_wheel (0.41.2)\nRoot-Is-Purelib: false\n"
            + "Tag: cp311-cp311-macosx_11_0_arm64\nTag: cp311-cp311-macosx_10_9_x86_64\n"
        let whl = try manifest("example_pkg-1.0.2-cp311-cp311-macosx_11_0_arm64.whl", [
            ("example_pkg/__init__.py", ""),
            ("example_pkg-1.0.2.dist-info/METADATA", metadata),
            ("example_pkg-1.0.2.dist-info/WHEEL", wheel),
            ("example_pkg-1.0.2.dist-info/RECORD", ""),
        ])
        XCTAssertEqual(whl?.kind, "Python wheel")
        XCTAssertEqual(whl?.source, "example_pkg-1.0.2.dist-info/METADATA")
        XCTAssertEqual(fields(whl), [
            "Name": "example-pkg",
            "Version": "1.0.2",
            "Summary": "A small example package",
            "Requires Python": ">=3.9",
            "Dependencies": "4 (2 only for extras)",
            "Tags": "cp311-cp311-macosx_11_0_arm64, cp311-cp311-macosx_10_9_x86_64",
        ])
        let headers = PackageManifest.headerFields(metadata)
        XCTAssertEqual(headers.first { $0.key == "Description" }?.value, "first line\ncontinued line")
        XCTAssertEqual(headers.filter { $0.key == "Name" }.count, 1)

        // A dist-info folder nested deeper isn't the wheel's own.
        XCTAssertNil(try manifest("other-1.0-py3-none-any.whl", [("vendor/x-1.0.dist-info/METADATA", "Name: x\n")]))
    }

    // MARK: - NuGet

    func testNuspec() throws {
        let nuspec = """
            <?xml version="1.0" encoding="utf-8"?>
            <package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd">
              <metadata>
                <id>Example.Logging</id>
                <version>2.0.0-beta.1</version>
                <authors>Example Corp, Jane Doe</authors>
                <description>
                  Structured logging for .NET.
                </description>
                <dependencies>
                  <group targetFramework="net8.0">
                    <dependency id="Microsoft.Extensions.Logging" version="8.0.0" />
                  </group>
                  <group targetFramework=".NETStandard2.0">
                    <dependency id="Microsoft.Extensions.Logging" version="6.0.0" />
                    <dependency id="System.Text.Json" version="6.0.0" />
                  </group>
                  <group targetFramework="" />
                </dependencies>
              </metadata>
            </package>
            """
        let package = try manifest("Example.Logging.2.0.0-beta.1.nupkg", [
            ("_rels/.rels", "<Relationships/>"),
            ("Example.Logging.nuspec", nuspec),
            ("lib/net8.0/Example.Logging.dll", "x"),
        ])
        XCTAssertEqual(package?.kind, "NuGet package")
        XCTAssertEqual(package?.source, "Example.Logging.nuspec")
        XCTAssertEqual(fields(package), [
            "ID": "Example.Logging",
            "Version": "2.0.0-beta.1",
            "Authors": "Example Corp, Jane Doe",
            "Description": "Structured logging for .NET.",
            "Dependencies": "2",
            "Frameworks": "net8.0, .NETStandard2.0",
        ])
        XCTAssertNil(try manifest("broken.nupkg", [("broken.nuspec", "<package><metadata>")]))
        XCTAssertNil(try manifest("nested.nupkg", [("content/inner.nuspec", nuspec)]))
    }

    // MARK: - Visual Studio and VS Code

    func testVSCodeExtensionResolvesPlaceholders() throws {
        let packageJSON = """
            {
              "name": "rainbow-csv",
              "displayName": "%displayName%",
              "description": "%description%",
              "version": "3.6.0",
              "publisher": "mechatroner",
              "engines": { "vscode": "^1.57.0", "node": ">=16" }
            }
            """
        let strings = #"{ "displayName": "Rainbow CSV", "description": { "message": "Highlight CSV columns", "comment": ["x"] } }"#
        let vsix = try manifest("rainbow-csv-3.6.0.vsix", [
            ("extension.vsixmanifest", "<PackageManifest/>"),
            ("extension/package.json", packageJSON),
            ("extension/package.nls.json", strings),
        ])
        XCTAssertEqual(vsix?.kind, "VS Code extension")
        XCTAssertEqual(fields(vsix), [
            "Name": "rainbow-csv",
            "Display name": "Rainbow CSV",
            "Version": "3.6.0",
            "Publisher": "mechatroner",
            "Engines": "node >=16, vscode ^1.57.0",
            "Description": "Highlight CSV columns",
        ])
    }

    func testVisualStudioExtensionManifest() throws {
        let manifestXML = """
            <?xml version="1.0" encoding="utf-8"?>
            <PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
              <Metadata>
                <Identity Language="en-US" Id="Example.Tools.1a2b" Version="1.4" Publisher="Example" />
                <DisplayName>Example Tools</DisplayName>
                <Description xml:space="preserve">Adds example commands.</Description>
              </Metadata>
              <Installation>
                <InstallationTarget Id="Microsoft.VisualStudio.Community" Version="[17.0,18.0)" />
                <InstallationTarget Id="Microsoft.VisualStudio.Pro" />
              </Installation>
            </PackageManifest>
            """
        let vsix = try manifest("ExampleTools.vsix", [("extension.vsixmanifest", manifestXML), ("Example.dll", "x")])
        XCTAssertEqual(vsix?.kind, "Visual Studio extension")
        XCTAssertEqual(fields(vsix), [
            "ID": "Example.Tools.1a2b",
            "Display name": "Example Tools",
            "Version": "1.4",
            "Publisher": "Example",
            "Targets": "Microsoft.VisualStudio.Community [17.0,18.0)\nMicrosoft.VisualStudio.Pro",
            "Description": "Adds example commands.",
        ])
    }

    // MARK: - Firefox

    func testFirefoxAddOnWithLocalizedNameAndComments() throws {
        let manifestJSON = """
            {
              // Comments are allowed in WebExtension manifests.
              "manifest_version": 3,
              "name": "__MSG_appName__",
              "version": "2.0.1",
              "default_locale": "en_US",
              "applications": { "gecko": { "id": "{9a3b1c2d-0000-4000-8000-123456789abc}" } },
              "permissions": ["storage", "alarms"],
              "host_permissions": ["https://*.example.com/*"],
              "description": "__MSG_missing__"
            }
            """
        let xpi = try manifest("addon.xpi", [
            ("manifest.json", manifestJSON),
            ("_locales/en_US/messages.json", #"{ "AppName": { "message": "Example Add-on" } }"#),
        ])
        XCTAssertEqual(xpi?.kind, "Firefox add-on")
        XCTAssertEqual(fields(xpi), [
            "Name": "Example Add-on",
            "Version": "2.0.1",
            "ID": "{9a3b1c2d-0000-4000-8000-123456789abc}",
            "Manifest version": "3",
            "Permissions": "2",
            "Host permissions": "1",
            "Description": "__MSG_missing__",
        ])
        XCTAssertNil(try manifest("legacy.xpi", [("install.rdf", "<RDF/>")]))
        XCTAssertNil(try manifest("broken.xpi", [("manifest.json", "{ not json")]))
    }

    // MARK: - Android

    func testAndroidPackagesSummarizeTheirFileList() throws {
        let apk = try manifest("app.apk", [
            ("AndroidManifest.xml", "binary"),
            ("classes.dex", "dex"), ("classes2.dex", "dex"),
            ("lib/arm64-v8a/libapp.so", "so"), ("lib/arm64-v8a/libc++_shared.so", "so"),
            ("lib/x86/libapp.so", "so"),
            ("assets/lib/fake/notalib.so", "so"),
            ("META-INF/CERT.SF", "sf"), ("META-INF/CERT.RSA", "rsa"),
        ])
        XCTAssertEqual(apk?.kind, "Android app")
        XCTAssertNil(apk?.source)
        XCTAssertEqual(fields(apk), [
            "Code": "2 dex files",
            "Native code": "arm64-v8a (2 libraries)\nx86 (1 library)",
            "Signatures": "v1 (CERT.RSA)",
        ])

        let bundle = try manifest("app.aab", [
            ("base/manifest/AndroidManifest.xml", "pb"),
            ("base/dex/classes.dex", "dex"), ("feature/dex/classes.dex", "dex"),
            ("base/lib/arm64-v8a/libapp.so", "so"),
            ("META-INF/KEY0.EC", "ec"),
        ])
        XCTAssertEqual(bundle?.kind, "Android App Bundle")
        XCTAssertEqual(fields(bundle), [
            "Code": "2 dex files", "Native code": "arm64-v8a (1 library)", "Signatures": "v1 (KEY0.EC)",
        ])

        let bare = try manifest("bare.apk", [("AndroidManifest.xml", "binary")])
        XCTAssertEqual(fields(bare), ["Code": "No dex files", "Native code": "None", "Signatures": "None found"])
    }

    /// An APK signing block sits between the last member and the central
    /// directory; v2+ signatures live only there.
    func testAPKSignatureSchemeBlock() throws {
        func pair(_ id: UInt32, _ value: [UInt8]) -> [UInt8] {
            var bytes: [UInt8] = []
            bytes.le64(UInt64(4 + value.count)); bytes.le32(id)
            return bytes + value
        }
        let pairs = pair(0x7109_871A, [1, 2, 3]) + pair(0xF053_68C0, [4]) + pair(0x4272_6577, [UInt8](repeating: 0, count: 9))
        var block: [UInt8] = []
        block.le64(UInt64(pairs.count + 8 + 16))
        block += pairs
        block.le64(UInt64(pairs.count + 8 + 16))
        block += Array("APK Sig Block 42".utf8)

        var bytes = [UInt8](zip([("classes.dex", "dex"), ("META-INF/CERT.RSA", "rsa")]))
        let end = bytes.count - 22
        let directory = Int(bytes[end + 16]) | Int(bytes[end + 17]) << 8 | Int(bytes[end + 18]) << 16 | Int(bytes[end + 19]) << 24
        bytes.insert(contentsOf: block, at: directory)
        let moved = UInt32(directory + block.count)
        for (index, shift) in [0, 8, 16, 24].enumerated() { bytes[end + block.count + 16 + index] = UInt8(moved >> UInt32(shift) & 0xFF) }

        let url = try write("signed.apk", Data(bytes))
        XCTAssertEqual(fields(try manifest(of: url))["Signatures"], "v1 (CERT.RSA), v2, v3")
        XCTAssertEqual(try ArchiveReader.listPackage(url, type: .apk).listing.entries.map(\.path),
                       ["classes.dex", "META-INF/CERT.RSA"])

        // A size that reaches past the start of the file, or a missing
        // magic, means there's no block to read.
        var bad = bytes
        bad[directory + block.count - 24 + 6] = 0x7F
        XCTAssertEqual(fields(try manifest(of: try write("bad.apk", Data(bad))))["Signatures"], "v1 (CERT.RSA)")
        var wrongMagic = bytes
        wrongMagic[directory + block.count - 1] = UInt8(ascii: "X")
        XCTAssertEqual(fields(try manifest(of: try write("magic.apk", Data(wrongMagic))))["Signatures"], "v1 (CERT.RSA)")
    }

    // MARK: - Packages that aren't what they say

    func testDamagedManifestMemberIsSkipped() throws {
        var bytes = [UInt8](zip([("META-INF/MANIFEST.MF", "Main-Class: A\n"), ("A.class", "x")]))
        // The stored manifest's bytes no longer match its CRC.
        let offset = 30 + "META-INF/MANIFEST.MF".utf8.count
        bytes[offset] ^= 0xFF
        let url = try write("crc.jar", Data(bytes))
        let (listing, manifest) = try ArchiveReader.listPackage(url, type: .jar)
        XCTAssertEqual(listing.entries.count, 2)
        XCTAssertNil(manifest)
    }

    func testPackagesThatAreReallyOtherArchivesListAsThose() throws {
        let gz = try run("/usr/bin/gzip", ["-c", try write("in/payload", repetitiveText(500)).path])
        let (listing, manifest) = try ArchiveReader.listPackage(try write("odd.jar", gz), type: .jar)
        XCTAssertTrue(listing.isSingleFile)
        XCTAssertNil(manifest)
        XCTAssertThrowsError(try ArchiveReader.listPackage(try write("text.whl", repetitiveText(500)), type: .whl))
    }

    func testReadsTheSampleFixtures() throws {
        let expected: [(String, String, String, String)] = [
            ("Sample.jar", "Java archive", "Main class", "com.example.sample.Main"),
            ("sample-1.0.0-py3-none-any.whl", "Python wheel", "Dependencies", "2 (1 only for extras)"),
            ("Spyglass.Sample.1.0.0.nupkg", "NuGet package", "ID", "Spyglass.Sample"),
            ("spyglass-sample-1.0.0.vsix", "VS Code extension", "Display name", "Spyglass Sample"),
            ("sample.xpi", "Firefox add-on", "Name", "Spyglass Sample"),
            ("Sample.apk", "Android app", "Native code", "arm64-v8a (1 library)\nx86_64 (1 library)"),
        ]
        for (name, kind, label, value) in expected {
            let manifest = try manifest(of: fixture(name))
            XCTAssertEqual(manifest?.kind, kind, name)
            XCTAssertEqual(fields(manifest)[label], value, name)
        }
    }

    func testPackageTypes() {
        XCTAssertEqual(PackageType(filename: "Tool.JAR"), .jar)
        XCTAssertEqual(PackageType(filename: "pkg-1.0-py3-none-any.whl"), .whl)
        XCTAssertNil(PackageType(filename: "archive.zip"))
        XCTAssertNil(PackageType(filename: "jar"))
    }
}
