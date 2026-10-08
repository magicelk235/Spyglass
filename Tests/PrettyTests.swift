import XCTest
@testable import SpyglassKit

final class PrettyTests: XCTestCase {

    // MARK: - JSON

    func testJSONKeepsKeyOrderNumbersAndEscapes() throws {
        let input = #"{"z":1,"a":{"m":[1.0,1e5,-0,12345678901234567890,-2.5E-3],"e":"caf\u00e9 a\/b"},"x":[],"y":{}}"#
        let expected = #"""
        {
          "z": 1,
          "a": {
            "m": [
              1.0,
              1e5,
              -0,
              12345678901234567890,
              -2.5E-3
            ],
            "e": "caf\u00e9 a\/b"
          },
          "x": [],
          "y": {}
        }
        """#
        XCTAssertEqual(try Pretty.json(input), PrettyText(text: expected, isCut: false))
    }

    func testJSONEmptyContainersStayCompact() throws {
        XCTAssertEqual(try Pretty.json("{}").text, "{}")
        XCTAssertEqual(try Pretty.json("[ ]").text, "[]")
        XCTAssertEqual(try Pretty.json(#"[{},[],{ }]"#).text, "[\n  {},\n  [],\n  {}\n]")
    }

    func testJSONScalarsAtTopLevel() throws {
        XCTAssertEqual(try Pretty.json(#"  "hi"  "#).text, #""hi""#)
        XCTAssertEqual(try Pretty.json("-0.5e+10").text, "-0.5e+10")
        XCTAssertEqual(try Pretty.json("null").text, "null")
    }

    func testJSONLinesStartEachValueOnItsOwnLine() throws {
        let input = "{\"a\":1}\n{\"b\":[2]}\r\n3 true"
        let expected = #"""
        {
          "a": 1
        }
        {
          "b": [
            2
          ]
        }
        3
        true
        """#
        XCTAssertEqual(try Pretty.json(input).text, expected)
    }

    func testJSONStringsWithPunctuationDontAffectIndentation() throws {
        let input = #"{"k":"[{,:}] \"q\" \\","l":[":",",","]"],"\"}":{}}"#
        let expected = #"""
        {
          "k": "[{,:}] \"q\" \\",
          "l": [
            ":",
            ",",
            "]"
          ],
          "\"}": {}
        }
        """#
        XCTAssertEqual(try Pretty.json(input).text, expected)
    }

    func testJSONKeepsNonASCIIText() throws {
        XCTAssertEqual(try Pretty.json(#"{"名前":"héllo 👋"}"#).text, "{\n  \"名前\": \"héllo 👋\"\n}")
    }

    func testJSONSkipsByteOrderMark() throws {
        XCTAssertEqual(try Pretty.json("\u{FEFF}[1,2]").text, "[\n  1,\n  2\n]")
    }

    func testMalformedJSONThrows() {
        let inputs = [
            "[1,2,]",
            #"{"a":1,}"#,
            "{'a':1}",
            #""abc"#,
            "01",
            "[01]",
            "1.",
            ".5",
            "-",
            "1e",
            "1.2.3",
            "+1",
            "nope",
            "truex",
            "[true false]",
            "\"a\u{01}b\"",
            "\"tab\there\"",
            #""\x""#,
            #""\u12G4""#,
            "[1}",
            "{\"a\" 1}",
            "{\"a\":}",
            "{1:2}",
            "]",
            "{}{}",
            "[1 2]",
            "",
            "  \n ",
            "\u{FEFF}",
        ]
        for input in inputs {
            XCTAssertThrowsError(try Pretty.json(input), "accepted \(input.debugDescription)") { error in
                guard case PrettyError.malformed = error else {
                    return XCTFail("wrong error for \(input.debugDescription): \(error)")
                }
            }
        }
    }

    func testTruncatedJSONEmitsWhatWasRead() throws {
        let input = #"{"name":"Ad","list":[1,2.5,tr"#
        let expected = #"""
        {
          "name": "Ad",
          "list": [
            1,
            2.5,
            tr
        """#
        XCTAssertEqual(try Pretty.json(input, allowTruncatedEnd: true), PrettyText(text: expected, isCut: false))
        XCTAssertThrowsError(try Pretty.json(input))
    }

    func testTruncatedJSONStopsAnywhere() throws {
        let cases: [(String, String)] = [
            (#"{"a":"unfinished str"#, "{\n  \"a\": \"unfinished str"),
            (#"{"a":"esc\"#, "{\n  \"a\": \"esc\\"),
            (#"["\u00"#, "[\n  \"\\u00"),
            (#"{"a""#, "{\n  \"a\""),
            (#"{"a":"#, "{\n  \"a\":"),
            ("[1,", "[\n  1,"),
            ("[[[", "[\n  [\n    ["),
            ("[-", "[\n  -"),
            ("[1.", "[\n  1."),
            ("[1e+", "[\n  1e+"),
            ("[nu", "[\n  nu"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(try Pretty.json(input, allowTruncatedEnd: true).text, expected, input)
            XCTAssertThrowsError(try Pretty.json(input), input)
        }
    }

    func testTruncationDoesNotHideErrorsBeforeTheEnd() {
        XCTAssertThrowsError(try Pretty.json("[1,,", allowTruncatedEnd: true))
        XCTAssertThrowsError(try Pretty.json(#"{"a":nul "#, allowTruncatedEnd: true))
        XCTAssertThrowsError(try Pretty.json("[1.x", allowTruncatedEnd: true))
    }

    func testOutputLimitCutsAtLineBoundary() throws {
        // Full output is "[\n  1,\n  2,\n  3,\n  4,\n  5\n]"; "[\n  1,\n  2," is 11 bytes.
        let cut = try Pretty.json("[1,2,3,4,5]", outputLimit: 12)
        XCTAssertEqual(cut, PrettyText(text: "[\n  1,\n  2,", isCut: true))

        let full = "[\n  1,\n  2,\n  3,\n  4,\n  5\n]"
        XCTAssertEqual(try Pretty.json("[1,2,3,4,5]", outputLimit: full.utf8.count),
                       PrettyText(text: full, isCut: false))
        XCTAssertEqual(try Pretty.json("[1,2,3,4,5]", outputLimit: full.utf8.count - 1),
                       PrettyText(text: "[\n  1,\n  2,\n  3,\n  4,\n  5", isCut: true))
    }

    func testOutputLimitDropsALongTokenThatOverflows() throws {
        let input = #"["short","\#(String(repeating: "x", count: 100))"]"#
        XCTAssertEqual(try Pretty.json(input, outputLimit: 40), PrettyText(text: "[\n  \"short\",", isCut: true))
        XCTAssertEqual(try Pretty.json(input, outputLimit: 0), PrettyText(text: "", isCut: true))
    }

    func testOutputLimitStillValidatesTheRest() {
        XCTAssertThrowsError(try Pretty.json("[1,2,3,4,5,]", outputLimit: 12))
        XCTAssertThrowsError(try Pretty.json(#"[1,2,3,4,"oops]"#, outputLimit: 12))
    }

    func testDeepNestingStaysWithinTheLimit() throws {
        let depth = 100_000
        let input = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let result = try Pretty.json(input, outputLimit: 4096)
        XCTAssertTrue(result.isCut)
        XCTAssertLessThanOrEqual(result.text.utf8.count, 4096)
        XCTAssertTrue(result.text.hasPrefix("[\n  [\n    ["))

        let open = String(repeating: "[", count: depth)
        XCTAssertThrowsError(try Pretty.json(open, outputLimit: 4096))
        let truncated = try Pretty.json(open, allowTruncatedEnd: true, outputLimit: 4096)
        XCTAssertLessThanOrEqual(truncated.text.utf8.count, 4096)
    }

    func testLargeMinifiedDocumentRoundTrips() throws {
        var input = "["
        var index = 0
        while input.utf8.count < 2_000_000 {
            if index > 0 { input += "," }
            input += #"{"id":\#(index),"name":"item \#(index)","tags":["a","b"],"score":\#(index).5,"ok":true}"#
            index += 1
        }
        input += "]"

        let pretty = try Pretty.json(input)
        XCTAssertFalse(pretty.isCut)
        XCTAssertTrue(pretty.text.hasPrefix("[\n  {\n    \"id\": 0,\n    \"name\": \"item 0\","))
        let original = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? NSArray
        let reparsed = try JSONSerialization.jsonObject(with: Data(pretty.text.utf8)) as? NSArray
        XCTAssertEqual(original?.count, index)
        XCTAssertEqual(original, reparsed)
    }

    // MARK: - XML

    func testMinifiedFeedIsIndentedAndKeepsDeclaration() throws {
        let input = #"<?xml version="1.0"?><rss version="2.0"><channel><title>News</title><item><link>https://e.com/1</link><empty></empty></item></channel></rss>"#
        let expected = """
        <?xml version="1.0"?>
        <rss version="2.0">
            <channel>
                <title>News</title>
                <item>
                    <link>https://e.com/1</link>
                    <empty/>
                </item>
            </channel>
        </rss>
        """
        XCTAssertEqual(try Pretty.xml(input), PrettyText(text: expected, isCut: false))
    }

    func testDeclarationIsKeptAsWritten() throws {
        let input = #"<?xml version="1.0" encoding="iso-8859-1" standalone="no"?><a><b/></a>"#
        XCTAssertEqual(try Pretty.xml(input).text,
                       "<?xml version=\"1.0\" encoding=\"iso-8859-1\" standalone=\"no\"?>\n<a>\n    <b/>\n</a>")
    }

    func testXMLWithoutDeclarationDoesNotGainOne() throws {
        let input = #"<root><a><b>t</b></a><c x="1"/></root>"#
        XCTAssertEqual(try Pretty.xml(input).text, "<root>\n    <a>\n        <b>t</b>\n    </a>\n    <c x=\"1\"/>\n</root>")
    }

    func testStylesheetInstructionIsNotTakenForTheDeclaration() throws {
        let input = #"<?xml-stylesheet href="s.css"?><a/>"#
        let text = try Pretty.xml(input).text
        XCTAssertFalse(text.hasPrefix("<?xml "))
        XCTAssertTrue(text.contains(#"<?xml-stylesheet href="s.css"?>"#))
    }

    func testXMLKeepsAttributeOrderCDATAAndComments() throws {
        let input = #"<a z="1" b="2" m="3"><![CDATA[<b>&x</b>]]><!-- note --></a>"#
        let text = try Pretty.xml(input).text
        XCTAssertTrue(text.hasPrefix(#"<a z="1" b="2" m="3">"#), text)
        XCTAssertTrue(text.contains("<![CDATA[<b>&x</b>]]>"), text)
        XCTAssertTrue(text.contains("<!-- note -->"), text)
    }

    func testMalformedXMLThrows() {
        for input in ["<a><b></a>", "not xml", "<a>", "", "<a x=1/>"] {
            XCTAssertThrowsError(try Pretty.xml(input), input) { error in
                guard case PrettyError.malformed = error else {
                    return XCTFail("wrong error for \(input.debugDescription): \(error)")
                }
            }
        }
    }

    func testExternalDTDIsNeverFetched() throws {
        // Nothing listens on port 9; a fetch would fail the parse or stall.
        let input = #"<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://127.0.0.1:9/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>a</key><string>b</string></dict></plist>"#
        let text = try Pretty.xml(input).text
        XCTAssertTrue(text.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC"), text)
        XCTAssertTrue(text.hasSuffix("""
        <plist version="1.0">
            <dict>
                <key>a</key>
                <string>b</string>
            </dict>
        </plist>
        """), text)
    }

    func testNoBlankLineAfterTheDoctype() throws {
        let input = #"<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><true/></plist>"#
        XCTAssertEqual(try Pretty.xml(input).text, """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
                <true/>
            </plist>
            """)
    }

    func testDeepXMLIsRejectedBeforeFormatting() {
        let input = String(repeating: "<a>", count: 2000) + String(repeating: "</a>", count: 2000)
        XCTAssertThrowsError(try Pretty.xml(input, outputLimit: 100_000)) { error in
            XCTAssertEqual(error as? PrettyError, .tooLarge)
        }
    }

    func testIndentationEstimateIgnoresMarkupThatIsNotATag() {
        let input = #"<r><!-- <x><x><x> --><![CDATA[<y><y>]]><a t="<z>"/><b></b></r>"#
        XCTAssertEqual(Pretty.estimatedXMLIndentation(input, giveUpAbove: .max), 2 * Pretty.xmlIndentWidth)
    }

    func testXMLOutputLimitCutsAtLineBoundary() throws {
        let input = "<r>" + String(repeating: "<i>x</i>", count: 200) + "</r>"
        let result = try Pretty.xml(input, outputLimit: 1000)
        XCTAssertTrue(result.isCut)
        XCTAssertLessThanOrEqual(result.text.utf8.count, 1000)
        XCTAssertTrue(result.text.hasPrefix("<r>\n    <i>x</i>\n"))
        XCTAssertTrue(result.text.hasSuffix("\n    <i>x</i>"))
    }

    // MARK: - Property lists

    func testBinaryPlistConvertsToXML() throws {
        let plist: [String: Any] = ["name": "Spyglass", "count": 3, "on": true]
        let binary = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertTrue(binary.starts(with: Array("bplist".utf8)))

        let xml = try Pretty.xmlPropertyList(from: binary)
        XCTAssertTrue(xml.hasPrefix("<?xml"))
        XCTAssertTrue(xml.contains("<key>name</key>\n\t<string>Spyglass</string>"), xml)
        XCTAssertTrue(xml.contains("<key>count</key>\n\t<integer>3</integer>"), xml)
        XCTAssertTrue(xml.contains("<key>on</key>\n\t<true/>"), xml)
    }

    func testOpenStepPlistConvertsToXML() throws {
        let xml = try Pretty.xmlPropertyList(from: Data(#"{ name = "Spyglass"; }"#.utf8))
        XCTAssertTrue(xml.contains("<key>name</key>\n\t<string>Spyglass</string>"), xml)
    }

    func testSharedReferencesThatWouldExplodeAreTooLarge() throws {
        // PropertyListSerialization writes every reference out in full, so the
        // bplist is assembled by hand: object 0 is the string "x", object 1 an
        // array of 100 references to it, each object up to 20 an array of 100
        // references to the one before, and object 21 the root holding object 20.
        // About 2 KB that stands for 100^20 strings.
        var data = Data("bplist00".utf8)
        var offsets: [Int] = []
        offsets.append(data.count)
        data.append(contentsOf: [0x51, UInt8(ascii: "x")])
        for previous in 0..<20 {
            offsets.append(data.count)
            data.append(contentsOf: [0xAF, 0x10, 100])
            data.append(contentsOf: repeatElement(UInt8(previous), count: 100))
        }
        offsets.append(data.count)
        data.append(contentsOf: [0xA1, 20])

        let offsetTable = data.count
        for offset in offsets {
            data.append(contentsOf: [UInt8(offset >> 8), UInt8(offset & 0xFF)])
        }
        // Trailer: six unused bytes, offset size 2, reference size 1, then object
        // count, top object and offset table position as 64-bit big-endian integers.
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 2, 1])
        for value in [offsets.count, offsets.count - 1, offsetTable] {
            data.append(contentsOf: (0..<8).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) })
        }

        let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        XCTAssertEqual((decoded as? NSArray)?.count, 1)

        let start = Date()
        XCTAssertThrowsError(try Pretty.xmlPropertyList(from: data)) { error in
            XCTAssertEqual(error as? PrettyError, .tooLarge)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testPlistOutputLimit() throws {
        let plist = ["items": Array(repeating: "an item", count: 100)]
        let binary = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertNoThrow(try Pretty.xmlPropertyList(from: binary))
        XCTAssertThrowsError(try Pretty.xmlPropertyList(from: binary, outputLimit: 1000)) { error in
            XCTAssertEqual(error as? PrettyError, .tooLarge)
        }
    }

    func testGarbageIsNotAPlist() {
        // A bare word like "bplist00garbage" is a valid OpenStep string, so the
        // broken binary header carries bytes no text plist allows.
        let brokenBinary = Data("bplist00".utf8) + Data([0xD5, 0x00, 0x01])
        for data in [Data([0x00, 0xFF, 0xFE, 0x13, 0x37]), brokenBinary, Data("{ a = ".utf8)] {
            XCTAssertThrowsError(try Pretty.xmlPropertyList(from: data)) { error in
                guard case PrettyError.malformed = error else { return XCTFail("\(error)") }
            }
        }
    }

    // MARK: - looksMinified

    func testOneLineBoundaryIsEightyCharacters() {
        XCTAssertFalse(Pretty.looksMinified(String(repeating: "a", count: 80)))
        XCTAssertTrue(Pretty.looksMinified(String(repeating: "a", count: 81)))
        // Characters, not bytes: 80 two-byte characters still fit.
        XCTAssertFalse(Pretty.looksMinified(String(repeating: "é", count: 80)))
    }

    func testTrailingWhitespaceIsIgnored() {
        XCTAssertFalse(Pretty.looksMinified(String(repeating: "a", count: 80) + "\n\n  \n"))
        XCTAssertFalse(Pretty.looksMinified(""))
        XCTAssertFalse(Pretty.looksMinified(" \n\t"))
    }

    func testTwoLinesCountTogether() {
        let line = String(repeating: "a", count: 41)
        XCTAssertTrue(Pretty.looksMinified(line + "\n" + line))
        XCTAssertFalse(Pretty.looksMinified("{\n}"))
    }

    func testThreeShortLinesAreHandFormatted() {
        let line = String(repeating: "a", count: 60)
        XCTAssertFalse(Pretty.looksMinified([line, line, line].joined(separator: "\n")))
    }

    func testOneVeryLongLineAnywhereIsMinified() {
        let lines = ["{", String(repeating: "a", count: 1000), "}"]
        XCTAssertFalse(Pretty.looksMinified(lines.joined(separator: "\n")))
        let longer = ["{", String(repeating: "a", count: 1001), "}"]
        XCTAssertTrue(Pretty.looksMinified(longer.joined(separator: "\n")))
    }

    // MARK: - displayText

    private let minifiedJSON = #"{"name":"Spyglass","version":"1.0","platforms":["macOS"],"settings":{"theme":"dark","fontSize":13}}"#

    func testHandFormattedJSONIsUntouched() {
        let input = "{\n    \"b\": 1,\n    \"a\":   [1,2]\n}"
        XCTAssertEqual(Pretty.displayText(input, format: .json, truncated: false), PrettyText(text: input, isCut: false))
    }

    func testMinifiedJSONIsFormatted() {
        let shown = Pretty.displayText(minifiedJSON, format: .json, truncated: false)
        XCTAssertEqual(shown.text, try Pretty.json(minifiedJSON).text)
        XCTAssertTrue(shown.text.hasPrefix("{\n  \"name\": \"Spyglass\",\n"))
    }

    func testTruncatedMinifiedJSONIsFormattedAsFarAsItGoes() {
        let cut = String(minifiedJSON.prefix(90))
        let shown = Pretty.displayText(cut, format: .json, truncated: true)
        XCTAssertTrue(shown.text.hasPrefix("{\n  \"name\": \"Spyglass\",\n"), shown.text)
        XCTAssertEqual(Pretty.displayText(cut, format: .json, truncated: false).text, cut)
    }

    func testMinifiedButMalformedJSONIsUntouched() {
        let input = minifiedJSON + ",}"
        XCTAssertEqual(Pretty.displayText(input, format: .json, truncated: false), PrettyText(text: input, isCut: false))
    }

    func testDisplayTextPassesTheOutputLimitThrough() {
        let shown = Pretty.displayText(minifiedJSON, format: .json, truncated: false, outputLimit: 30)
        XCTAssertEqual(shown, PrettyText(text: "{\n  \"name\": \"Spyglass\",", isCut: true))
    }

    func testMinifiedXMLIsFormattedUnlessTruncated() {
        let input = "<library><book id=\"1\"><title>Dune</title></book><book id=\"2\"><title>Emma</title></book></library>"
        XCTAssertTrue(Pretty.displayText(input, format: .xml, truncated: false).text.hasPrefix("<library>\n    <book id=\"1\">"))
        XCTAssertEqual(Pretty.displayText(input, format: .xml, truncated: true).text, input)
    }

    func testMalformedXMLIsUntouched() {
        let input = "<library><book id=\"1\"><title>Dune</title></book><book id=\"2\"><title>Emma</title></library>"
        XCTAssertEqual(Pretty.displayText(input, format: .xml, truncated: false).text, input)
    }

    func testYAMLAndTOMLAreUntouched() {
        let yaml = "items: [" + String(repeating: "alpha, ", count: 20) + "omega]"
        XCTAssertEqual(Pretty.displayText(yaml, format: .yaml, truncated: false), PrettyText(text: yaml, isCut: false))
        let toml = "list = [" + String(repeating: "1, ", count: 40) + "2]"
        XCTAssertEqual(Pretty.displayText(toml, format: .toml, truncated: false).text, toml)
    }

    func testXMLPlistIsFormattedAndOpenStepIsUntouched() {
        let xmlPlist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>name</key><string>Spyglass</string></dict></plist>"#
        XCTAssertEqual(Pretty.displayText(xmlPlist, format: .plist, truncated: false).text, """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
            <dict>
                <key>name</key>
                <string>Spyglass</string>
            </dict>
        </plist>
        """)

        let openStep = #"{ name = "Spyglass"; version = "1.0"; platforms = ( macOS ); settings = { theme = dark; }; }"#
        XCTAssertEqual(Pretty.displayText(openStep, format: .plist, truncated: false), PrettyText(text: openStep, isCut: false))
    }
}
