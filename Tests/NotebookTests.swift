import XCTest
@testable import SpyglassKit

final class NotebookTests: ArchiveTestCase {

    private typealias Output = Notebook.Output
    private typealias Image = Notebook.Image

    // MARK: - Helpers

    private func notebook(cells: [Any], metadata: [String: Any] = [:], nbformat: Int = 4,
                          limits: Notebook.Limits = .standard) throws -> Notebook {
        let object: [String: Any] = ["cells": cells, "metadata": metadata, "nbformat": nbformat, "nbformat_minor": 5]
        return try Notebook.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), limits: limits)
    }

    private func codeCell(_ source: Any = "", count: Any = NSNull(), outputs: [Any] = []) -> [String: Any] {
        ["cell_type": "code", "execution_count": count, "metadata": [:], "outputs": outputs, "source": source]
    }

    private func display(_ data: [String: Any], metadata: [String: Any] = [:]) -> [String: Any] {
        ["output_type": "display_data", "data": data, "metadata": metadata]
    }

    private func stream(_ name: String, _ text: Any) -> [String: Any] {
        ["output_type": "stream", "name": name, "text": text]
    }

    private func outputs(_ outputs: [Any], limits: Notebook.Limits = .standard) throws -> [Output] {
        try notebook(cells: [codeCell(outputs: outputs)], limits: limits).cells[0].outputs
    }

    // MARK: - Cells

    func testSourceIsAStringOrAnArrayOfLines() throws {
        let nb = try notebook(cells: [
            ["cell_type": "markdown", "metadata": [:], "source": ["# Title\n", "\n", "Text"]],
            ["cell_type": "markdown", "metadata": [:], "source": "# Title\n\nText"],
            codeCell(["x = 1\n", "y = 2"]),
        ])
        XCTAssertEqual(nb.cells.map(\.source), ["# Title\n\nText", "# Title\n\nText", "x = 1\ny = 2"])
    }

    func testCellKindsAndExecutionCounts() throws {
        let nb = try notebook(cells: [
            ["cell_type": "markdown", "source": "m"],
            codeCell("a", count: 7),
            codeCell("b"),
            ["cell_type": "raw", "source": "r"],
        ])
        XCTAssertEqual(nb.cells.map(\.kind), [.markdown, .code, .code, .raw])
        XCTAssertEqual(nb.cells.map(\.executionCount), [nil, 7, nil, nil])
        XCTAssertEqual(nb.cellCount, 4)
    }

    func testMissingFieldsFallBackToDefaults() throws {
        let nb = try notebook(cells: [
            ["cell_type": "code"],
            ["source": "no type"],
            42,
            ["cell_type": "markdown", "source": [1, "kept", NSNull()]],
            codeCell("x", count: true, outputs: [
                ["text": "no output type"],
                ["output_type": "stream", "text": "to stdout"],
                ["output_type": "stream", "name": "stderr"],
                ["output_type": "execute_result", "execution_count": 1],
                ["output_type": "update_display_data", "data": ["text/plain": "?"]],
                ["output_type": "error"],
                ["output_type": "error", "ename": "KeyError", "evalue": "'a'"],
                "not an output",
            ]),
        ])
        XCTAssertEqual(nb.cells.map(\.kind), [.code, .raw, .markdown, .code])
        XCTAssertEqual(nb.cellCount, 4, "42 isn't a cell")
        XCTAssertEqual(nb.cells.map(\.source), ["", "no type", "kept", "x"])
        XCTAssertEqual(nb.cells.map(\.executionCount), [nil, nil, nil, nil])
        XCTAssertEqual(nb.cells[0].outputs, [])
        XCTAssertEqual(nb.cells[3].outputs, [
            Output(content: .stream(name: "stdout", text: ANSIText("to stdout"))),
            Output(content: .error(ANSIText("Error"))),
            Output(content: .error(ANSIText("KeyError: 'a'"))),
        ])
        XCTAssertNil(nb.language)
    }

    func testCellsPastTheCapAreLeftOut() throws {
        let cells = (0..<7).map { ["cell_type": "markdown", "source": "cell \($0)"] }
        let nb = try notebook(cells: cells, limits: Notebook.Limits(maxCells: 5))
        XCTAssertEqual(nb.cells.map(\.source), (0..<5).map { "cell \($0)" })
        XCTAssertEqual(nb.cellCount, 7)
    }

    // MARK: - Outputs

    func testOutputsKeepTheirOrder() throws {
        let traceback = "\u{1B}[0;31mValueError\u{1B}[0m: bad"
        let result = try outputs([
            stream("stdout", ["line 1\n", "line 2\n"]),
            display(["text/plain": "<Figure>", "image/png": "UE5H"]),
            stream("stderr", "warning\n"),
            ["output_type": "execute_result", "execution_count": 4, "data": ["text/plain": ["4", "2"]], "metadata": [:]],
            ["output_type": "error", "ename": "ValueError", "evalue": "bad", "traceback": ["-----", traceback]],
        ])
        XCTAssertEqual(result, [
            Output(content: .stream(name: "stdout", text: ANSIText("line 1\nline 2\n"))),
            Output(content: .image(Image(mimeType: "image/png", base64: "UE5H"))),
            Output(content: .stream(name: "stderr", text: ANSIText("warning\n"))),
            Output(content: .text(ANSIText("42")), executionCount: 4),
            Output(content: .error(ANSIText("-----\n" + traceback))),
        ])
        guard case .error(let text) = result[4].content else { return XCTFail() }
        XCTAssertEqual(text.runs.first { $0.text == "ValueError" }?.style.foreground, .palette(1))
    }

    func testConsecutiveStreamsWithTheSameNameAreJoined() throws {
        // Joined before carriage returns are worked out, so a progress bar
        // written in pieces still ends up on one line.
        let result = try outputs([
            stream("stdout", "a"), stream("stdout", " 10%\r"), stream("stdout", "b 90%\n"),
            stream("stderr", "warn"), stream("stdout", "c"),
        ])
        XCTAssertEqual(result, [
            Output(content: .stream(name: "stdout", text: ANSIText("b 90%\n"))),
            Output(content: .stream(name: "stderr", text: ANSIText("warn"))),
            Output(content: .stream(name: "stdout", text: ANSIText("c"))),
        ])
    }

    func testEachMimeBundleShowsOneRepresentationInPreferenceOrder() throws {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#
        let bundles: [[String: Any]] = [
            ["text/plain": "p", "text/html": "<b>h</b>", "image/png": "UE5H", "image/jpeg": "SlBH"],
            ["text/plain": "p", "image/jpeg": "SlBH", "image/svg+xml": svg],
            ["text/plain": "p", "image/svg+xml": [svg], "text/html": "<b>h</b>"],
            ["text/plain": "p", "text/latex": "$x$", "text/markdown": "**m**", "text/html": ["<b>", "h</b>"]],
            ["text/plain": "p", "text/latex": "$x$", "text/markdown": "**m**"],
            ["text/plain": "p", "text/latex": "$x$"],
            ["text/plain": "p", "application/json": ["a": 1]],
            ["application/vnd.plotly.v1+json": ["data": []], "text/html": "<div></div>"],
        ]
        // SVG is passed on as image data, never as markup.
        let svgBase64 = Data(svg.utf8).base64EncodedString()
        XCTAssertEqual(try outputs(bundles.map { display($0) }).map(\.content), [
            .image(Image(mimeType: "image/png", base64: "UE5H")),
            .image(Image(mimeType: "image/jpeg", base64: "SlBH")),
            .image(Image(mimeType: "image/svg+xml", base64: svgBase64)),
            .html("<b>h</b>"),
            .markdown("**m**"),
            .latex("$x$"),
            .text(ANSIText("p")),
            .html("<div></div>"),
        ])
    }

    func testBundlesWithNothingShowableAreLeftOut() throws {
        XCTAssertEqual(try outputs([
            display(["application/json": ["a": 1]]),
            display(["text/html": "", "image/png": ""]),
            display([:]),
            ["output_type": "display_data", "data": "not a bundle"],
        ]), [])
    }

    func testImageSizeAndBackgroundComeFromMetadata() throws {
        let result = try outputs([
            display(["image/png": "UE5H"], metadata: ["image/png": ["width": 320, "height": 240], "needs_background": "light"]),
            display(["image/jpeg": "SlBH"], metadata: ["image/jpeg": ["width": "wide", "height": -5, "needs_background": "dark"]]),
            display(["image/png": "UE5H"], metadata: ["needs_background": "plaid"]),
        ])
        XCTAssertEqual(result.map(\.content), [
            .image(Image(mimeType: "image/png", base64: "UE5H", width: 320, height: 240, background: "light")),
            .image(Image(mimeType: "image/jpeg", base64: "SlBH", background: "dark")),
            .image(Image(mimeType: "image/png", base64: "UE5H")),
        ])
    }

    func testImagesPastTheBudgetBecomePlaceholders() throws {
        let big = String(repeating: "A", count: 60), small = String(repeating: "B", count: 30)
        let nb = try notebook(cells: [codeCell(outputs: [
            display(["image/png": big]),
            display(["image/png": big, "text/plain": "a figure"]),
            display(["image/png": small]),
        ])], limits: Notebook.Limits(imageBudget: 100))
        XCTAssertEqual(nb.cells[0].outputs.map(\.content), [
            .image(Image(mimeType: "image/png", base64: big)),
            .omittedImage(mimeType: "image/png", size: 45),
            .image(Image(mimeType: "image/png", base64: small)),
        ])
        XCTAssertEqual(nb.omittedImageCount, 1)
    }

    func testMarkdownAttachmentsAreKeptByNameAndCountTowardTheBudget() throws {
        let nb = try notebook(cells: [
            ["cell_type": "markdown", "source": "![](attachment:plot.png)", "attachments": [
                "plot.png": ["image/png": "UE5H"],
                "notes.txt": ["text/plain": "not an image"],
                "huge.png": ["image/png": String(repeating: "A", count: 200)],
            ]],
        ], limits: Notebook.Limits(imageBudget: 100))
        XCTAssertEqual(nb.cells[0].attachments, [Notebook.Attachment(name: "plot.png", image: Image(mimeType: "image/png", base64: "UE5H"))])
        XCTAssertEqual(nb.omittedImageCount, 1)
    }

    // MARK: - Kernel language

    func testLanguageComesFromTheKernel() throws {
        let cases: [([String: Any], String?)] = [
            (["kernelspec": ["language": "python", "name": "python3"]], "python"),
            (["kernelspec": ["language": "R"]], "r"),
            (["kernelspec": ["language": "C++17"]], "cpp"),
            (["language_info": ["name": "julia", "file_extension": ".jl"]], "julia"),
            (["language_info": ["name": "octave", "file_extension": ".m"]], "matlab"),
            (["kernelspec": ["language": "mystery"], "language_info": ["name": "scala"]], "scala"),
            (["language_info": ["name": "mystery", "file_extension": ".py"]], "python"),
            (["language_info": ["name": "mystery"]], nil),
            (["kernelspec": "python"], nil),
            ([:], nil),
        ]
        for (metadata, expected) in cases {
            XCTAssertEqual(try notebook(cells: [], metadata: metadata).language, expected, "\(metadata)")
        }
    }

    // MARK: - nbformat versions

    func testReadsVersion3() throws {
        let json = #"""
        {
         "metadata": {"name": "old"},
         "nbformat": 3,
         "nbformat_minor": 0,
         "worksheets": [{"cells": [
           {"cell_type": "heading", "level": 2, "metadata": {}, "source": ["Results"]},
           {"cell_type": "markdown", "metadata": {}, "source": ["Some *text*"]},
           {"cell_type": "code", "collapsed": false, "input": ["print 'hi'\n", "1 + 1"], "language": "python",
            "metadata": {}, "prompt_number": 3, "outputs": [
             {"output_type": "stream", "stream": "stdout", "text": ["hi\n"]},
             {"output_type": "pyout", "prompt_number": 3, "metadata": {}, "text": ["2"], "html": ["<b>2</b>"]},
             {"output_type": "display_data", "metadata": {}, "png": "UE5H", "text": ["<matplotlib.figure.Figure>"]},
             {"output_type": "pyerr", "ename": "NameError", "evalue": "x", "traceback": ["\u001b[0;31mNameError\u001b[0m: x"]}
           ]},
           {"cell_type": "raw", "metadata": {}, "source": ["raw text"]}
         ], "metadata": {}}]
        }
        """#
        let nb = try Notebook.decode(Data(json.utf8))
        XCTAssertEqual(nb.language, "python")
        XCTAssertEqual(nb.cells.map(\.kind), [.markdown, .markdown, .code, .raw])
        XCTAssertEqual(nb.cells.map(\.source), ["## Results", "Some *text*", "print 'hi'\n1 + 1", "raw text"])
        XCTAssertEqual(nb.cells[2].executionCount, 3)
        XCTAssertEqual(nb.cells[2].outputs, [
            Output(content: .stream(name: "stdout", text: ANSIText("hi\n"))),
            Output(content: .html("<b>2</b>"), executionCount: 3),
            Output(content: .image(Image(mimeType: "image/png", base64: "UE5H"))),
            Output(content: .error(ANSIText("\u{1B}[0;31mNameError\u{1B}[0m: x"))),
        ])
    }

    func testOlderVersionsThrow() {
        XCTAssertThrowsError(try Notebook.decode(Data(#"{"nbformat": 2, "worksheets": [{"cells": []}]}"#.utf8))) { error in
            XCTAssertEqual(error as? NotebookError, .unsupportedVersion(2))
        }
    }

    func testNewerVersionsReadLikeVersion4() throws {
        let nb = try Notebook.decode(Data(#"{"nbformat": 5, "cells": [{"cell_type": "raw", "source": "x"}]}"#.utf8))
        XCTAssertEqual(nb.cells.map(\.source), ["x"])
    }

    func testMalformedInputThrows() throws {
        let inputs = ["", "{", "[]", "null", "42", "not json", #"{"cells": 3}"#, #"{"cells": {}}"#,
                      #"{"nbformat": 4}"#, #"{"nbformat": 3}"#, #"{"cells": [{"cell_type": "code"}"#]
        for input in inputs {
            XCTAssertThrowsError(try Notebook.decode(Data(input.utf8)), input)
        }
        let sample = try Data(contentsOf: fixture("analysis.ipynb"))
        XCTAssertNoThrow(try Notebook.decode(sample))
        XCTAssertThrowsError(try Notebook.decode(sample.prefix(sample.count / 2)))
    }

    func testReadsTheSampleNotebook() throws {
        let nb = try Notebook.read(at: fixture("analysis.ipynb"))
        XCTAssertEqual(nb.language, "python")
        XCTAssertNil(nb.cut)
        XCTAssertEqual(nb.omittedImageCount, 0)
        XCTAssertEqual(nb.cells.map(\.kind), [.raw, .markdown, .code, .code, .markdown, .code, .code, .code, .markdown, .code])
        XCTAssertEqual(nb.cells.map(\.executionCount), [nil, nil, 1, 2, nil, 3, 4, 5, nil, nil])

        let outputs = nb.cells.flatMap(\.outputs)
        XCTAssertEqual(outputs.count, 6)
        guard case .stream("stdout", let stdout) = outputs[0].content,
              case .stream("stderr", let stderr) = outputs[1].content,
              case .html(let table) = outputs[2].content,
              case .image(let plot) = outputs[3].content,
              case .latex(let latex) = outputs[4].content,
              case .error(let traceback) = outputs[5].content else {
            return XCTFail("\(outputs.map(\.content))")
        }
        XCTAssertEqual(stdout.string, "Loaded 1,204 rows from 4 regions\n")
        XCTAssertTrue(stderr.string.contains("DtypeWarning"))
        XCTAssertTrue(table.contains(#"<table border="1" class="dataframe">"#))
        XCTAssertEqual(outputs[2].executionCount, 2)
        XCTAssertEqual(plot.mimeType, "image/png")
        XCTAssertEqual(Data(base64Encoded: plot.base64)?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(latex, #"$\displaystyle \hat{y}_t = 40.4 + 3.82\,t$"#)
        XCTAssertTrue(traceback.string.hasSuffix("KeyError: 'Antarctica'"), traceback.string)
        XCTAssertFalse(traceback.string.contains("\u{1B}"))
        XCTAssertTrue(traceback.runs.contains { $0.style.background == .palette(3) })
    }

    // MARK: - File size limit

    /// A notebook file with the cells' JSON at known offsets.
    private func notebookText(head: String, cells: [[String: Any]], tail: String) throws -> (text: String, cellStarts: [Int]) {
        let cellJSON = try cells.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
        var starts: [Int] = []
        var offset = head.utf8.count
        for json in cellJSON {
            starts.append(offset)
            offset += json.utf8.count + 2
        }
        return (head + cellJSON.joined(separator: ", ") + tail, starts)
    }

    func testLongFilesShowTheCellsThatFitInTheReadLimit() throws {
        // Brackets, braces and escaped quotes inside strings mustn't count.
        let source = "x = {\"k\": [1]}  # ] } \\\" [ {"
        let (text, starts) = try notebookText(
            head: #"{"cells": ["#,
            cells: (0..<5).map { codeCell(source, count: $0) },
            tail: #"], "metadata": {"kernelspec": {"display_name": "Julia 1.10", "language": "julia", "name": "julia-1.10"}}, "nbformat": 4, "nbformat_minor": 5}"#)
        let url = try write("long.ipynb", text)
        let limit = starts[3] + 20

        let nb = try Notebook.read(at: url, limits: Notebook.Limits(maxFileSize: limit))
        XCTAssertEqual(nb.cells.map(\.executionCount), [0, 1, 2])
        XCTAssertEqual(nb.cells.map(\.source), Array(repeating: source, count: 3))
        XCTAssertEqual(nb.language, "julia", "read from the end of the file")
        XCTAssertEqual(nb.cut, Notebook.Cut(readBytes: limit, fileSize: text.utf8.count))

        let whole = try Notebook.read(at: url, limits: Notebook.Limits(maxFileSize: text.utf8.count))
        XCTAssertEqual(whole.cells.count, 5)
        XCTAssertNil(whole.cut)
    }

    func testMetadataBeforeTheCellsSurvivesTheCut() throws {
        // Colab writes the metadata first.
        let (text, starts) = try notebookText(
            head: #"{"nbformat": 4, "nbformat_minor": 0, "metadata": {"kernelspec": {"language": "R"}}, "cells": ["#,
            cells: (0..<3).map { codeCell("x <- \($0)", count: $0) },
            tail: "]}")
        let url = try write("colab.ipynb", text)
        let nb = try Notebook.read(at: url, limits: Notebook.Limits(maxFileSize: starts[2] + 5))
        XCTAssertEqual(nb.cells.map(\.source), ["x <- 0", "x <- 1"])
        XCTAssertEqual(nb.language, "r")
    }

    func testAFirstCellLongerThanTheLimitThrows() throws {
        let (text, _) = try notebookText(head: #"{"cells": ["#, cells: [codeCell(String(repeating: "x", count: 1000))], tail: "]}")
        let url = try write("one.ipynb", text)
        XCTAssertThrowsError(try Notebook.read(at: url, limits: Notebook.Limits(maxFileSize: 500))) { error in
            XCTAssertEqual(error as? NotebookError, .tooLarge)
        }
    }

    // MARK: - Page payload

    func testEncodesTheShapeThePageReads() throws {
        let nb = try notebook(cells: [
            ["cell_type": "markdown", "source": "![](attachment:a.png)", "attachments": ["a.png": ["image/png": "UE5H"]]],
            codeCell("print(1)", count: 1, outputs: [
                stream("stderr", "w"),
                ["output_type": "execute_result", "execution_count": 1, "data": ["text/plain": "1"], "metadata": [:]],
                display(["text/html": "<b>h</b>"]),
                display(["text/markdown": "m"]),
                display(["text/latex": "l"]),
                display(["image/png": "UE5H"], metadata: ["image/png": ["width": 10], "needs_background": "light"]),
                display(["image/png": String(repeating: "A", count: 8)]),
                ["output_type": "error", "ename": "E", "evalue": "v", "traceback": []],
            ]),
            ["cell_type": "raw", "source": "r"],
        ], metadata: ["kernelspec": ["language": "python"]], limits: Notebook.Limits(imageBudget: 10))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(String(decoding: try encoder.encode(nb), as: UTF8.self), """
            {"cells":[\
            {"attachments":[{"name":"a.png","url":"data:image/png;base64,UE5H"}],"source":"![](attachment:a.png)","type":"markdown"},\
            {"count":1,"outputs":[\
            {"name":"stderr","text":[{"text":"w"}],"type":"stream"},\
            {"count":1,"text":[{"text":"1"}],"type":"text"},\
            {"html":"<b>h</b>","type":"html"},\
            {"text":"m","type":"markdown"},\
            {"text":"l","type":"latex"},\
            {"background":"light","data":"UE5H","mime":"image/png","type":"image","width":10},\
            {"mime":"image/png","size":6,"type":"omitted"},\
            {"text":[{"text":"E: v"}],"type":"error"}\
            ],"source":"print(1)","type":"code"},\
            {"source":"r","type":"raw"}\
            ],"language":"python"}
            """)
    }
}
