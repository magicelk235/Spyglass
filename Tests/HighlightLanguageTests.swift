import JavaScriptCore
import XCTest
@testable import SpyglassKit

/// Every language id the router hands the code view has to exist in the
/// vendored highlight.js build. An unknown id doesn't fail visibly: that
/// file type would just lose its colors.
final class HighlightLanguageTests: XCTestCase {

    func testEveryRoutedLanguageExistsInTheBundledHighlighter() throws {
        let vendor = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Preview/Web/vendor/highlight")
        let context = try XCTUnwrap(JSContext())
        for file in ["highlight.min.js", "languages.min.js"] {
            context.evaluateScript(try String(contentsOf: vendor.appendingPathComponent(file), encoding: .utf8))
            XCTAssertNil(context.exception, "\(file) failed to load: \(String(describing: context.exception))")
        }

        var ids = Set(CodeLanguage.byExtension.values).union(CodeLanguage.byFilename.values)
        ids.formUnion(PreviewKind.codeUTIs.values.compactMap { $0 })
        for case .code(language: let language?) in PreviewKind.byUTI.values {
            ids.insert(language)
        }
        // The structured-text and diff renderers pick these themselves.
        ids.formUnion(["json", "xml", "yaml", "toml", "diff", "plaintext"])
        XCTAssertGreaterThan(ids.count, 60)

        let exists = try XCTUnwrap(context.evaluateScript("(id) => hljs.getLanguage(id) !== undefined"))
        for id in ids.sorted() {
            XCTAssertTrue(exists.call(withArguments: [id]).toBool(), "highlight.js has no grammar for \"\(id)\"")
        }
    }
}
