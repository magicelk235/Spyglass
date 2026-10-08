import XCTest
@testable import SpyglassKit

/// Configuration profiles are usually CMS-signed. These sign one with a
/// throwaway self-signed certificate, the way `openssl smime` (or an MDM
/// server) does.
final class SignedPropertyListTests: ArchiveTestCase {

    private let profile: [String: Any] = [
        "PayloadDisplayName": "Office Wi-Fi",
        "PayloadIdentifier": "com.example.wifi",
        "PayloadType": "Configuration",
        "PayloadVersion": 1,
        "PayloadContent": [["PayloadType": "com.apple.wifi.managed", "SSID_STR": "Office"]],
    ]

    private func openssl() throws -> String {
        let tool = ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipIf(tool == nil, "openssl isn't installed")
        return tool!
    }

    /// `content` signed as DER with the content embedded.
    private func sign(_ content: Data, commonName: String = "Spyglass Test Signer") throws -> Data {
        let tool = try openssl()
        try write("content", content)
        try run(tool, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                       "-subj", "/CN=\(commonName)/O=Spyglass Tests", "-keyout", "key.pem", "-out", "cert.pem"])
        try run(tool, ["smime", "-sign", "-binary", "-nodetach", "-outform", "der", "-in", "content",
                       "-signer", "cert.pem", "-inkey", "key.pem", "-out", "signed.mobileconfig"])
        return try Data(contentsOf: dir.appendingPathComponent("signed.mobileconfig"))
    }

    func testSignedProfileIsUnwrapped() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        let signed = try sign(xml)
        XCTAssertNil(try? PropertyListSerialization.propertyList(from: signed, format: nil), "signed data isn't a plist itself")

        let result = try XCTUnwrap(try Pretty.signedPropertyList(signed))
        XCTAssertEqual(result.signer, "Spyglass Test Signer")
        XCTAssertFalse(result.text.isCut)
        XCTAssertTrue(result.text.text.hasPrefix(#"<?xml version="1.0" encoding="UTF-8"?>"#), result.text.text)
        XCTAssertTrue(result.text.text.contains("""
            <plist version="1.0">
                <dict>
                    <key>PayloadContent</key>
                    <array>
                        <dict>
            """), result.text.text)
    }

    func testMachineWrittenContentIsAlwaysReindented() throws {
        // A signing tool's output: declaration and DOCTYPE on lines of their
        // own, then the whole plist on one line that isn't especially long.
        let content = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>PayloadDisplayName</key><string>Office  Wi-Fi </string><key>PayloadVersion</key><integer>1</integer></dict></plist>
            """
        XCTAssertFalse(Pretty.looksMinified(content))
        let result = try XCTUnwrap(try Pretty.signedPropertyList(sign(Data(content.utf8))))
        XCTAssertEqual(result.text.text, """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
                <dict>
                    <key>PayloadDisplayName</key>
                    <string>Office  Wi-Fi </string>
                    <key>PayloadVersion</key>
                    <integer>1</integer>
                </dict>
            </plist>
            """)
    }

    func testOpenStepContentIsShownAsWritten() throws {
        let openStep = #"{ PayloadDisplayName = "Office Wi-Fi"; PayloadVersion = 1; }"#
        let result = try XCTUnwrap(try Pretty.signedPropertyList(sign(Data(openStep.utf8))))
        XCTAssertEqual(result.text, PrettyText(text: openStep, isCut: false))
    }

    func testBinaryContentIsShownAsXML() throws {
        let binary = try PropertyListSerialization.data(fromPropertyList: profile, format: .binary, options: 0)
        let result = try XCTUnwrap(try Pretty.signedPropertyList(sign(binary)))
        XCTAssertTrue(result.text.text.contains("<key>PayloadIdentifier</key>\n\t<string>com.example.wifi</string>"), result.text.text)
    }

    func testSignedContentThatIsNotAPropertyListThrows() throws {
        let signed = try sign(Data([0x00, 0xFF, 0x13, 0x37, 0x00]))
        XCTAssertThrowsError(try Pretty.signedPropertyList(signed)) { error in
            guard case PrettyError.malformed = error else { return XCTFail("\(error)") }
        }
    }

    func testDataThatIsNotSignedIsLeftAlone() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        XCTAssertNil(try Pretty.signedPropertyList(xml))
        XCTAssertNil(try Pretty.signedPropertyList(Data()))
        // A DER SEQUENCE that isn't CMS.
        XCTAssertNil(try Pretty.signedPropertyList(Data([0x30, 0x03, 0x02, 0x01, 0x05])))
        XCTAssertNil(try Pretty.signedPropertyList(Data([0x30])))

        let signed = try sign(xml)
        XCTAssertNil(try Pretty.signedPropertyList(signed.prefix(signed.count / 2)), "cut-off signed data")
    }
}
