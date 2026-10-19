import XCTest
@testable import SpyglassKit

final class ANSITextTests: XCTestCase {

    private typealias Run = ANSIText.Run
    private typealias Style = ANSIText.Style

    private func runs(_ text: String, maxRuns: Int = 20_000) -> [Run] {
        ANSIText(text, maxRuns: maxRuns).runs
    }

    private func red(_ style: Style = Style()) -> Style {
        var style = style
        style.foreground = .palette(1)
        return style
    }

    // MARK: - Plain text

    func testPlainTextIsOneUnstyledRun() {
        XCTAssertEqual(runs("hello\n\tworld"), [Run(text: "hello\n\tworld", style: Style())])
    }

    func testEmptyTextHasNoRuns() {
        XCTAssertEqual(runs(""), [])
        XCTAssertEqual(runs("\u{1B}[31m\u{1B}[0m"), [])
    }

    func testNonASCIITextSurvives() {
        XCTAssertEqual(runs("\u{1B}[31m日本語 ✓ 👋\u{1B}[0m!"),
                       [Run(text: "日本語 ✓ 👋", style: red()), Run(text: "!", style: Style())])
    }

    // MARK: - SGR

    func testStandardColorsAndReset() {
        XCTAssertEqual(runs("\u{1B}[31mred\u{1B}[0m plain \u{1B}[44mon blue"), [
            Run(text: "red", style: red()),
            Run(text: " plain ", style: Style()),
            Run(text: "on blue", style: Style(background: .palette(4))),
        ])
    }

    func testBrightColorsFollowTheStandardOnes() {
        XCTAssertEqual(runs("\u{1B}[91;102mx"), [Run(text: "x", style: Style(foreground: .palette(9), background: .palette(10)))])
    }

    func testParametersCombineAndAllowLeadingZeros() {
        // IPython writes "01" for bold and "0;31" for a reset then red.
        XCTAssertEqual(runs("\u{1B}[01;32mok\u{1B}[0;31mbad"), [
            Run(text: "ok", style: Style(foreground: .palette(2), bold: true)),
            Run(text: "bad", style: red()),
        ])
    }

    func testEmptyParameterListResets() {
        XCTAssertEqual(runs("\u{1B}[31mA\u{1B}[mB\u{1B}[31;mC"), [
            Run(text: "A", style: red()),
            // "31;" ends with an empty parameter, which is a reset too.
            Run(text: "BC", style: Style()),
        ])
    }

    func test256ColorPalette() {
        // IPython 8 marks the failing expression with gray 241 on yellow.
        XCTAssertEqual(runs("\u{1B}[38;5;241;43m1/0\u{1B}[39;49m!"), [
            Run(text: "1/0", style: Style(foreground: .rgb(98, 98, 98), background: .palette(3))),
            Run(text: "!", style: Style()),
        ])
        XCTAssertEqual(runs("\u{1B}[38;5;9ma\u{1B}[38;5;196mb\u{1B}[48;5;16mc\u{1B}[38;5;231md"), [
            Run(text: "a", style: Style(foreground: .palette(9))),
            Run(text: "b", style: Style(foreground: .rgb(255, 0, 0))),
            Run(text: "c", style: Style(foreground: .rgb(255, 0, 0), background: .rgb(0, 0, 0))),
            Run(text: "d", style: Style(foreground: .rgb(255, 255, 255), background: .rgb(0, 0, 0))),
        ])
    }

    func testTrueColor() {
        XCTAssertEqual(runs("\u{1B}[38;2;10;20;30;48;2;255;128;0mx"),
                       [Run(text: "x", style: Style(foreground: .rgb(10, 20, 30), background: .rgb(255, 128, 0)))])
        // Colon-separated sub-parameters mean the same.
        XCTAssertEqual(runs("\u{1B}[38:5:1mx"), [Run(text: "x", style: Style(foreground: .palette(1)))])
    }

    func testIncompleteOrOutOfRangeExtendedColorsAreIgnored() {
        XCTAssertEqual(runs("\u{1B}[38;5mA\u{1B}[38;5;256mB\u{1B}[38;2;1;2mC\u{1B}[38;2;1;2;999mD\u{1B}[38;7;1mE"),
                       [Run(text: "ABCDE", style: Style())])
        // What follows an ignored color still applies.
        XCTAssertEqual(runs("\u{1B}[38;5;300;1mx"), [Run(text: "x", style: Style(bold: true))])
    }

    func testAttributesTurnOnAndOff() {
        XCTAssertEqual(runs("\u{1B}[1;3;4ma\u{1B}[22mb\u{1B}[2mc\u{1B}[22;23;24md"), [
            Run(text: "a", style: Style(bold: true, italic: true, underline: true)),
            Run(text: "b", style: Style(italic: true, underline: true)),
            Run(text: "c", style: Style(faint: true, italic: true, underline: true)),
            Run(text: "d", style: Style()),
        ])
    }

    func testUnknownCodesAreIgnoredAndTheRestStillApply() {
        // Blink, inverse and strike-through aren't supported.
        XCTAssertEqual(runs("\u{1B}[5;7;9mx\u{1B}[31;5;53my"), [
            Run(text: "x", style: Style()),
            Run(text: "y", style: red()),
        ])
        XCTAssertEqual(runs("\u{1B}[99999999999999999999999mx"), [Run(text: "x", style: Style())])
    }

    func testDefaultColorCodesClearOnlyTheirColor() {
        XCTAssertEqual(runs("\u{1B}[1;31;42ma\u{1B}[39mb\u{1B}[49mc"), [
            Run(text: "a", style: Style(foreground: .palette(1), background: .palette(2), bold: true)),
            Run(text: "b", style: Style(background: .palette(2), bold: true)),
            Run(text: "c", style: Style(bold: true)),
        ])
    }

    // MARK: - Other escapes and controls

    func testOtherEscapeSequencesAreStripped() {
        // Erase line, cursor up, private mode, OSC 8 hyperlink, charset selection.
        let text = "a\u{1B}[2Kb\u{1B}[1Ac\u{1B}[?25ld\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{1B}\\e\u{1B}(Bf\u{1B}7g"
        XCTAssertEqual(runs(text), [Run(text: "abcdlinkefg", style: Style())])
    }

    func testCutOffEscapesAreDropped() {
        XCTAssertEqual(runs("ok\u{1B}[3"), [Run(text: "ok", style: Style())])
        XCTAssertEqual(runs("ok\u{1B}"), [Run(text: "ok", style: Style())])
        XCTAssertEqual(runs("ok\u{1B}]8;;never ends"), [Run(text: "ok", style: Style())])
        // A sequence broken by a byte that can't be part of it ends there.
        XCTAssertEqual(runs("\u{1B}[3\nnext"), [Run(text: "\nnext", style: Style())])
        XCTAssertEqual(runs("\u{1B}é"), [Run(text: "é", style: Style())])
    }

    func testControlCharactersAreDroppedButTabsAndNewlinesStay() {
        XCTAssertEqual(runs("a\u{07}b\tc\nd\u{08}\u{00}\u{7F}e"), [Run(text: "ab\tc\nde", style: Style())])
    }

    // MARK: - Carriage returns

    func testCarriageReturnStartsTheLineOver() {
        XCTAssertEqual(ANSIText("10%\r50%\r100%\ndone").string, "100%\ndone")
        XCTAssertEqual(ANSIText("one\ntwo 10%\rtwo 90%").string, "one\ntwo 90%")
    }

    func testCarriageReturnBeforeANewlineOrAtTheEndIsIgnored() {
        XCTAssertEqual(ANSIText("a\r\nb").string, "a\nb")
        XCTAssertEqual(ANSIText("abc\r").string, "abc")
        XCTAssertEqual(ANSIText("abc\r\r\nx").string, "abc\nx")
    }

    func testCarriageReturnDropsStyledRunsOnItsLineButKeepsTheStyle() {
        XCTAssertEqual(runs("first\n\u{1B}[31mred\u{1B}[0m plain\r\u{1B}[32mnew"), [
            Run(text: "first\n", style: Style()),
            Run(text: "new", style: Style(foreground: .palette(2))),
        ])
        XCTAssertEqual(runs("\u{1B}[31mred 10%\rred 20%"), [Run(text: "red 20%", style: red())])
    }

    // MARK: - Limits and encoding

    func testPastTheRunCapTheRestIsOnePlainRun() {
        let text = (0..<100).map { "\u{1B}[\(31 + $0 % 2)m\($0)" }.joined()
        let capped = ANSIText(text, maxRuns: 10)
        XCTAssertEqual(capped.runs.count, 10)
        XCTAssertEqual(capped.runs.prefix(9).map(\.text), (0..<9).map(String.init))
        XCTAssertEqual(capped.runs.last, Run(text: (9..<100).map(String.init).joined(), style: Style()))
        XCTAssertEqual(ANSIText(text).runs.count, 100)
        XCTAssertEqual(ANSIText(text, maxRuns: 1).runs, [Run(text: (0..<100).map(String.init).joined(), style: Style())])
    }

    func testEncodesRunsCompactly() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = ANSIText("\u{1B}[1;31;48;2;10;20;30mx\u{1B}[0;2;3;4my\u{1B}[0mz")
        XCTAssertEqual(String(decoding: try encoder.encode(text), as: UTF8.self), """
            [{"bg":"#0a141e","bold":true,"fg":1,"text":"x"},\
            {"faint":true,"italic":true,"text":"y","underline":true},\
            {"text":"z"}]
            """)
    }
}
