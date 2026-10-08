import XCTest
@testable import SpyglassKit

final class ShebangTests: XCTestCase {

    func testInterpreterPaths() {
        XCTAssertEqual(Shebang.language(for: "#!/bin/sh\necho hi\n"), "bash")
        XCTAssertEqual(Shebang.language(for: "#!/bin/bash -e\n"), "bash")
        XCTAssertEqual(Shebang.language(for: "#!/bin/zsh"), "bash")
        XCTAssertEqual(Shebang.language(for: "#!/usr/bin/python3.12\nimport os\n"), "python")
        XCTAssertEqual(Shebang.language(for: "#!/usr/local/bin/ruby2.7\r\nputs 1\r\n"), "ruby")
        XCTAssertEqual(Shebang.language(for: "#!/usr/bin/perl -w\n"), "perl")
        XCTAssertEqual(Shebang.language(for: "#!/usr/bin/php8.2\n"), "php")
        XCTAssertEqual(Shebang.language(for: "#! /usr/bin/node\n"), "javascript")
        XCTAssertEqual(Shebang.language(for: "#!/usr/bin/osascript\n"), "applescript")
    }

    func testEnvFindsTheCommandPastItsOwnArguments() {
        XCTAssertEqual(Shebang.language(for: "#!/usr/bin/env python3\n"), "python")
        XCTAssertEqual(Shebang.language(for: "#!/usr/bin/env node\n"), "javascript")
        XCTAssertEqual(Shebang.language(for: "#!/usr/bin/env -S ruby --disable-gems\n"), "ruby")
        XCTAssertEqual(Shebang.language(for: "#!/usr/bin/env -u HOME PYTHONPATH=. pypy3 -O\n"), "python")
        XCTAssertNil(Shebang.language(for: "#!/usr/bin/env\n"))
        XCTAssertNil(Shebang.language(for: "#!/usr/bin/env -i\n"))
    }

    func testOnlyTheFirstLineCounts() {
        XCTAssertNil(Shebang.language(for: "echo hi\n#!/bin/sh\n"))
        XCTAssertNil(Shebang.language(for: " #!/bin/sh\n"))
        XCTAssertNil(Shebang.language(for: ""))
        XCTAssertNil(Shebang.language(for: "#!"))
        XCTAssertNil(Shebang.language(for: "#!\n/bin/sh\n"))
        XCTAssertNil(Shebang.language(for: "#!/usr/bin/some-unknown-tool\n"))
    }

    /// Every language a shebang can name is one the code view already
    /// routes by extension, so the bundled highlighter has its grammar.
    func testLanguagesAreOnesTheCodeViewHighlights() {
        let routed = Set(CodeLanguage.byExtension.values)
        for (interpreter, language) in Shebang.interpreters {
            XCTAssertTrue(routed.contains(language), "\(interpreter) → \(language)")
        }
    }
}
