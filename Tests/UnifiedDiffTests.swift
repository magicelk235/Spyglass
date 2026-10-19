import XCTest
@testable import SpyglassKit

final class UnifiedDiffTests: XCTestCase {

    private typealias Line = UnifiedDiff.Line

    func testMultiFileGitDiff() throws {
        let diff = try UnifiedDiff.parse("""
            diff --git a/Sources/App.swift b/Sources/App.swift
            index 3b18e51..a1f9c2d 100644
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -10,4 +10,5 @@ struct App {
                 let name: String
            -    let id: Int
            +    let id: UUID
            +    let created: Date
                 var body: some View {
            @@ -40,2 +41,2 @@ extension App {
            -    print("old")
            +    print("new")
                 return
            diff --git a/README.md b/README.md
            new file mode 100644
            index 0000000..e69de29
            --- /dev/null
            +++ b/README.md
            @@ -0,0 +1,2 @@
            +# Title
            +Body

            """)
        XCTAssertEqual(diff.preamble, "")
        XCTAssertEqual(diff.files.count, 2)

        let app = diff.files[0]
        XCTAssertEqual(app.status, .modified)
        XCTAssertEqual(app.oldPath, "Sources/App.swift")
        XCTAssertEqual(app.newPath, "Sources/App.swift")
        XCTAssertNil(app.oldMode)
        XCTAssertNil(app.newMode)
        XCTAssertEqual(app.additions, 3)
        XCTAssertEqual(app.deletions, 2)
        XCTAssertEqual(app.hunks.count, 2)
        XCTAssertEqual(app.hunks[0].heading, "struct App {")
        XCTAssertEqual(app.hunks[0].lines, [
            Line(kind: .context, text: "    let name: String", oldLine: 10, newLine: 10),
            Line(kind: .removed, text: "    let id: Int", oldLine: 11),
            Line(kind: .added, text: "    let id: UUID", newLine: 11),
            Line(kind: .added, text: "    let created: Date", newLine: 12),
            Line(kind: .context, text: "    var body: some View {", oldLine: 12, newLine: 13),
        ])
        XCTAssertEqual(app.hunks[1].oldStart, 40)
        XCTAssertEqual(app.hunks[1].newStart, 41)
        XCTAssertEqual(app.hunks[1].lines.last, Line(kind: .context, text: "    return", oldLine: 41, newLine: 42))

        let readme = diff.files[1]
        XCTAssertEqual(readme.status, .added)
        XCTAssertNil(readme.oldPath)
        XCTAssertEqual(readme.newPath, "README.md")
        XCTAssertEqual(readme.newMode, "100644")
        XCTAssertEqual(readme.additions, 2)
        XCTAssertEqual(readme.deletions, 0)
        XCTAssertEqual(readme.hunks[0].lines[1], Line(kind: .added, text: "Body", newLine: 2))
    }

    func testRenameWithSimilarityAndNoHunks() throws {
        let diff = try UnifiedDiff.parse("""
            diff --git a/old name.txt b/docs/new name.txt
            similarity index 100%
            rename from old name.txt
            rename to docs/new name.txt
            """)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.status, .renamed)
        XCTAssertEqual(file.similarity, 100)
        XCTAssertEqual(file.oldPath, "old name.txt")
        XCTAssertEqual(file.newPath, "docs/new name.txt")
        XCTAssertEqual(file.hunks, [])
        XCTAssertEqual(file.additions, 0)
    }

    func testRenameWithHunks() throws {
        let diff = try UnifiedDiff.parse("""
            diff --git a/lib/util.c b/lib/helpers.c
            similarity index 92%
            rename from lib/util.c
            rename to lib/helpers.c
            index 1111111..2222222 100644
            --- a/lib/util.c
            +++ b/lib/helpers.c
            @@ -1,3 +1,3 @@
             #include <stdio.h>
            -int util(void);
            +int helper(void);
             int main(void);
            """)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.status, .renamed)
        XCTAssertEqual(file.similarity, 92)
        XCTAssertEqual(file.oldPath, "lib/util.c")
        XCTAssertEqual(file.newPath, "lib/helpers.c")
        XCTAssertEqual(file.hunks.count, 1)
        XCTAssertEqual(file.hunks[0].lines[2], Line(kind: .added, text: "int helper(void);", newLine: 2))
        XCTAssertEqual(file.hunks[0].lines[3], Line(kind: .context, text: "int main(void);", oldLine: 3, newLine: 3))
        XCTAssertEqual(file.additions, 1)
        XCTAssertEqual(file.deletions, 1)
    }

    func testCopy() throws {
        let diff = try UnifiedDiff.parse("""
            diff --git a/template.yml b/config.yml
            similarity index 85%
            copy from template.yml
            copy to config.yml
            index 1111111..3333333 100644
            --- a/template.yml
            +++ b/config.yml
            @@ -2 +2 @@ root:
            -  name: TEMPLATE
            +  name: production
            """)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.status, .copied)
        XCTAssertEqual(file.similarity, 85)
        XCTAssertEqual(file.oldPath, "template.yml")
        XCTAssertEqual(file.newPath, "config.yml")
        XCTAssertEqual(file.hunks[0].heading, "root:")
    }

    func testDeletedFile() throws {
        let diff = try UnifiedDiff.parse("""
            diff --git a/obsolete.sh b/obsolete.sh
            deleted file mode 100755
            index 5b2c3d4..0000000
            --- a/obsolete.sh
            +++ /dev/null
            @@ -1,2 +0,0 @@
            -#!/bin/sh
            -echo bye
            """)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.status, .deleted)
        XCTAssertEqual(file.oldPath, "obsolete.sh")
        XCTAssertNil(file.newPath)
        XCTAssertEqual(file.oldMode, "100755")
        XCTAssertNil(file.newMode)
        XCTAssertEqual(file.deletions, 2)
        XCTAssertEqual(file.hunks[0].lines[1], Line(kind: .removed, text: "echo bye", oldLine: 2))
    }

    func testModeOnlyChange() throws {
        let diff = try UnifiedDiff.parse("""
            diff --git a/build.sh b/build.sh
            old mode 100644
            new mode 100755
            diff --git a/run.sh b/run.sh
            old mode 100755
            new mode 100644
            """)
        XCTAssertEqual(diff.files.count, 2)
        let file = diff.files[0]
        XCTAssertEqual(file.status, .modified)
        XCTAssertEqual(file.oldPath, "build.sh")
        XCTAssertEqual(file.newPath, "build.sh")
        XCTAssertEqual(file.oldMode, "100644")
        XCTAssertEqual(file.newMode, "100755")
        XCTAssertEqual(file.hunks, [])
        XCTAssertEqual(diff.files[1].oldMode, "100755")
    }

    func testBinaryFilesDiffer() throws {
        let diff = try UnifiedDiff.parse("""
            diff --git a/logo.png b/logo.png
            index 1111111..2222222 100644
            Binary files a/logo.png and b/logo.png differ
            diff --git a/icon.png b/icon.png
            new file mode 100644
            index 0000000..3333333
            Binary files /dev/null and b/icon.png differ
            """)
        XCTAssertEqual(diff.files.count, 2)
        XCTAssertTrue(diff.files[0].isBinary)
        XCTAssertEqual(diff.files[0].status, .modified)
        XCTAssertEqual(diff.files[0].oldPath, "logo.png")
        XCTAssertTrue(diff.files[1].isBinary)
        XCTAssertEqual(diff.files[1].status, .added)
        XCTAssertNil(diff.files[1].oldPath)
        XCTAssertEqual(diff.files[1].newPath, "icon.png")
    }

    func testRecursivePlainDiffBinaryLine() throws {
        let diff = try UnifiedDiff.parse("""
            diff -r old/photo.jpg new/photo.jpg
            Binary files old/photo.jpg and new/photo.jpg differ
            """)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertTrue(file.isBinary)
        XCTAssertEqual(file.oldPath, "old/photo.jpg")
        XCTAssertEqual(file.newPath, "new/photo.jpg")
    }

    func testGitBinaryPatchIsSkipped() throws {
        let diff = try UnifiedDiff.parse("""
            diff --git a/font.woff2 b/font.woff2
            new file mode 100644
            index 0000000000000000000000000000000000000000..9d5b6a4c1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b
            GIT binary patch
            literal 24
            fcmZQzKn4H(5C9+o0ssOH0RRA20RRIE
            ccmZQz00000

            literal 0
            HcmV?d00001

            diff --git a/notes.txt b/notes.txt
            --- a/notes.txt
            +++ b/notes.txt
            @@ -1 +1 @@
            -a
            +b
            """)
        XCTAssertEqual(diff.files.count, 2)
        let font = diff.files[0]
        XCTAssertTrue(font.isBinary)
        XCTAssertEqual(font.status, .added)
        XCTAssertEqual(font.newPath, "font.woff2")
        XCTAssertEqual(font.hunks, [])
        XCTAssertEqual(diff.files[1].newPath, "notes.txt")
        XCTAssertEqual(diff.files[1].additions, 1)
    }

    func testNoNewlineMarkers() throws {
        let diff = try UnifiedDiff.parse(#"""
            --- a.txt
            +++ b.txt
            @@ -1,2 +1,2 @@
             same
            -last
            \ No newline at end of file
            +last line
            \ No newline at end of file
            """#)
        let lines = try XCTUnwrap(diff.files.first?.hunks.first?.lines)
        XCTAssertEqual(lines, [
            Line(kind: .context, text: "same", oldLine: 1, newLine: 1),
            Line(kind: .removed, text: "last", oldLine: 2),
            Line(kind: .noNewline, text: "No newline at end of file"),
            Line(kind: .added, text: "last line", newLine: 2),
            Line(kind: .noNewline, text: "No newline at end of file"),
        ])
    }

    func testPlainDiffKeepsPrefixLikePathsAndDropsTimestamps() throws {
        let diff = try UnifiedDiff.parse("""
            diff -u a/config.ini b/config.ini
            --- a/config.ini\t2024-03-01 10:00:00.000000000 +0100
            +++ b/config.ini\t2024-03-02 11:30:00.000000000 +0100
            @@ -1 +1 @@
            -debug=true
            +debug=false
            """)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.oldPath, "a/config.ini")
        XCTAssertEqual(file.newPath, "b/config.ini")
        XCTAssertEqual(file.status, .modified)
    }

    func testBareFileHeadersStartEachFile() throws {
        let diff = try UnifiedDiff.parse("""
            --- one.txt
            +++ one.txt
            @@ -1 +1 @@
            -1
            +one
            --- two.txt
            +++ two.txt
            @@ -1 +1 @@
            -2
            +two
            """)
        XCTAssertEqual(diff.files.map(\.newPath), ["one.txt", "two.txt"])
        XCTAssertEqual(diff.files[1].hunks[0].lines[1].text, "two")
    }

    func testHunkHeaderWithoutCountsAndWithHeading() throws {
        let diff = try UnifiedDiff.parse("""
            --- a.py
            +++ b.py
            @@ -7 +7 @@   def handler(event):  
            -    return None
            +    return event
            """)
        let hunk = try XCTUnwrap(diff.files.first?.hunks.first)
        XCTAssertEqual(hunk.oldStart, 7)
        XCTAssertEqual(hunk.oldCount, 1)
        XCTAssertEqual(hunk.newStart, 7)
        XCTAssertEqual(hunk.newCount, 1)
        XCTAssertEqual(hunk.heading, "def handler(event):")
        XCTAssertEqual(hunk.lines[1], Line(kind: .added, text: "    return event", newLine: 7))
    }

    func testBlankLineInsideHunkIsEmptyContext() throws {
        let diff = try UnifiedDiff.parse("""
            --- a.txt
            +++ b.txt
            @@ -1,3 +1,3 @@
             first

            -third
            +THIRD
            """)
        let lines = try XCTUnwrap(diff.files.first?.hunks.first?.lines)
        XCTAssertEqual(lines[1], Line(kind: .context, text: "", oldLine: 2, newLine: 2))
        XCTAssertEqual(lines[2], Line(kind: .removed, text: "third", oldLine: 3))
        XCTAssertEqual(lines.count, 4)
    }

    func testFormatPatchPreambleAndSignature() throws {
        let diff = try UnifiedDiff.parse("""
            From 4f1c2a7b8d9e0f1a2b3c4d5e6f708192a3b4c5d6 Mon Sep 17 00:00:00 2001
            From: Jane Doe <jane@example.com>
            Date: Tue, 3 Sep 2024 10:00:00 +0200
            Subject: [PATCH] Fix the greeting

            The old greeting was rude.
            ---
             hello.txt | 2 +-
             1 file changed, 1 insertion(+), 1 deletion(-)

            diff --git a/hello.txt b/hello.txt
            index 1111111..2222222 100644
            --- a/hello.txt
            +++ b/hello.txt
            @@ -1 +1 @@
            -go away
            +hello
            --\u{20}
            2.39.0


            """)
        XCTAssertEqual(diff.preamble, """
            From 4f1c2a7b8d9e0f1a2b3c4d5e6f708192a3b4c5d6 Mon Sep 17 00:00:00 2001
            From: Jane Doe <jane@example.com>
            Date: Tue, 3 Sep 2024 10:00:00 +0200
            Subject: [PATCH] Fix the greeting

            The old greeting was rude.
            ---
             hello.txt | 2 +-
             1 file changed, 1 insertion(+), 1 deletion(-)
            """)
        XCTAssertEqual(diff.files.count, 1)
        let file = diff.files[0]
        XCTAssertEqual(file.hunks[0].lines.count, 2)
        XCTAssertEqual(file.additions, 1)
        XCTAssertEqual(file.deletions, 1)
    }

    func testInputCutMidHunkKeepsLinesPresent() throws {
        let diff = try UnifiedDiff.parse("""
            diff --git a/big.txt b/big.txt
            --- a/big.txt
            +++ b/big.txt
            @@ -1,100 +1,100 @@
             one
            -two
            +TWO
             thr
            """)
        let hunk = try XCTUnwrap(diff.files.first?.hunks.first)
        XCTAssertEqual(hunk.oldCount, 100)
        XCTAssertEqual(hunk.lines.count, 4)
        XCTAssertEqual(hunk.lines[3], Line(kind: .context, text: "thr", oldLine: 3, newLine: 3))
    }

    func testInputCutInFileHeader() throws {
        let diff = try UnifiedDiff.parse("""
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1 +1 @@
            -x
            +y
            diff --git a/b.txt b/b.txt
            index 1111111..22
            """)
        XCTAssertEqual(diff.files.count, 2)
        XCTAssertEqual(diff.files[1].newPath, "b.txt")
        XCTAssertEqual(diff.files[1].hunks, [])
    }

    func testCRLFInput() throws {
        let text = "diff --git a/w.txt b/w.txt\r\n--- a/w.txt\r\n+++ b/w.txt\r\n@@ -1,2 +1,2 @@\r\n keep\r\n-old\r\n+new\r\n"
        let file = try XCTUnwrap(UnifiedDiff.parse(text).files.first)
        XCTAssertEqual(file.newPath, "w.txt")
        XCTAssertEqual(file.hunks[0].lines, [
            Line(kind: .context, text: "keep", oldLine: 1, newLine: 1),
            Line(kind: .removed, text: "old", oldLine: 2),
            Line(kind: .added, text: "new", newLine: 2),
        ])
    }

    func testQuotedPathWithOctalUTF8() throws {
        let diff = try UnifiedDiff.parse(#"""
            diff --git "a/caf\303\251 \"menu\".txt" "b/caf\303\251 \"menu\".txt"
            index 1111111..2222222 100644
            --- "a/caf\303\251 \"menu\".txt"
            +++ "b/caf\303\251 \"menu\".txt"
            @@ -1 +1 @@
            -a\tb
            +a\\b
            """#)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.oldPath, "café \"menu\".txt")
        XCTAssertEqual(file.newPath, "café \"menu\".txt")
        // Escapes belong to path quoting only; hunk text stays literal.
        XCTAssertEqual(file.hunks[0].lines[1].text, #"a\\b"#)
    }

    func testQuotedPathEscapes() throws {
        let diff = try UnifiedDiff.parse(#"""
            diff --git "a/tab\there" "b/tab\there"
            old mode 100644
            new mode 100755
            """#)
        XCTAssertEqual(diff.files.first?.newPath, "tab\there")
    }

    func testGitPathWithSpacesAndNoFileHeaders() throws {
        let diff = try UnifiedDiff.parse("""
            diff --git a/My b/report final.pdf b/My b/report final.pdf
            index 1111111..2222222 100644
            Binary files a/My b/report final.pdf and b/My b/report final.pdf differ
            """)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.oldPath, "My b/report final.pdf")
        XCTAssertEqual(file.newPath, "My b/report final.pdf")
        XCTAssertTrue(file.isBinary)
    }

    func testMnemonicPrefixesAreStripped() throws {
        let diff = try UnifiedDiff.parse("""
            diff --git i/src/main.rs w/src/main.rs
            --- i/src/main.rs
            +++ w/src/main.rs
            @@ -1 +1 @@
            -fn main() {}
            +fn main() { run() }
            """)
        XCTAssertEqual(diff.files.first?.oldPath, "src/main.rs")
        XCTAssertEqual(diff.files.first?.newPath, "src/main.rs")
    }

    func testNoPrefixGitDiffKeepsPaths() throws {
        let diff = try UnifiedDiff.parse("""
            diff --git a/x.txt a/x.txt
            --- a/x.txt
            +++ a/x.txt
            @@ -1 +1 @@
            -1
            +2
            """)
        XCTAssertEqual(diff.files.first?.oldPath, "a/x.txt")
    }

    func testSvnDiff() throws {
        let diff = try UnifiedDiff.parse("""
            Index: trunk/main.c
            ===================================================================
            --- trunk/main.c\t(revision 41)
            +++ trunk/main.c\t(working copy)
            @@ -3,2 +3,2 @@
            -int x = 1;
            +int x = 2;
             return x;
            Index: trunk/util.c
            ===================================================================
            --- trunk/util.c\t(revision 41)
            +++ trunk/util.c\t(working copy)
            @@ -1 +1 @@
            -a
            +b
            """)
        XCTAssertEqual(diff.preamble, "")
        XCTAssertEqual(diff.files.map(\.oldPath), ["trunk/main.c", "trunk/util.c"])
        XCTAssertEqual(diff.files[0].hunks[0].lines.count, 3)
    }

    func testNoDiffThrows() {
        XCTAssertThrowsError(try UnifiedDiff.parse("Just some notes.\nNothing to see here.\n")) { error in
            XCTAssertEqual(error as? UnifiedDiffError, .noFiles)
        }
        XCTAssertThrowsError(try UnifiedDiff.parse("")) { error in
            XCTAssertEqual(error as? UnifiedDiffError, .noFiles)
        }
    }

    func testProseStartingWithDiffIsNotAFile() {
        XCTAssertThrowsError(try UnifiedDiff.parse("diff the two folders before merging\n")) { error in
            XCTAssertEqual(error as? UnifiedDiffError, .noFiles)
        }
    }

    func testMalformedHunkHeaderThrowsWithLineNumber() {
        let text = """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1 +1 @@
            -x
            +y
            @@ -oops +3 @@
            """
        XCTAssertThrowsError(try UnifiedDiff.parse(text)) { error in
            XCTAssertEqual(error as? UnifiedDiffError, .malformedHunkHeader(line: 7))
        }
    }

    func testCombinedDiffHeaderThrows() {
        let text = """
            diff --cc merged.txt
            index 1111111,2222222..3333333
            --- a/merged.txt
            +++ b/merged.txt
            @@@ -1,1 -1,1 +1,1 @@@
            """
        XCTAssertThrowsError(try UnifiedDiff.parse(text)) { error in
            XCTAssertEqual(error as? UnifiedDiffError, .malformedHunkHeader(line: 5))
        }
    }

    func testOversizedHunkNumbersThrowInsteadOfOverflowing() {
        let text = """
            --- a
            +++ b
            @@ -1,99999999999999999999 +1 @@
            """
        XCTAssertThrowsError(try UnifiedDiff.parse(text)) { error in
            XCTAssertEqual(error as? UnifiedDiffError, .malformedHunkHeader(line: 3))
        }
    }

    func testJSONOmitsMissingLineNumbersAndPaths() throws {
        let diff = try UnifiedDiff.parse("""
            --- /dev/null
            +++ new.txt
            @@ -0,0 +1 @@
            +hi
            """)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(diff.files[0].hunks[0].lines[0]), encoding: .utf8))
        XCTAssertFalse(json.contains("oldLine"))
        XCTAssertTrue(json.contains(#""newLine":1"#))
        XCTAssertTrue(json.contains(#""kind":"added""#))
        let file = try XCTUnwrap(String(data: JSONEncoder().encode(diff.files[0]), encoding: .utf8))
        XCTAssertFalse(file.contains("oldPath"))
        XCTAssertTrue(file.contains(#""status":"added""#))
    }

    func testLargeDiffParsesEveryLine() throws {
        var text = "diff --git a/big.txt b/big.txt\n--- a/big.txt\n+++ b/big.txt\n"
        for hunk in 0..<5_000 {
            let start = hunk * 10 + 1
            text += "@@ -\(start),7 +\(start),7 @@ func f\(hunk)()\n"
            text += " context line with some text to fill the row out\n"
            text += "-removed line with some text to fill the row out\n"
            text += "-removed line with some text to fill the row out\n"
            text += "+added line with some text to fill the row out\n"
            text += "+added line with some text to fill the row out\n"
            text += " context line with some text to fill the row out\n"
            text += " context line with some text to fill the row out\n"
            text += " context line with some text to fill the row out\n"
            text += " context line with some text to fill the row out\n"
        }
        let file = try XCTUnwrap(UnifiedDiff.parse(text).files.first)
        XCTAssertEqual(file.hunks.count, 5_000)
        XCTAssertEqual(file.additions, 10_000)
        XCTAssertEqual(file.deletions, 10_000)
        XCTAssertEqual(file.hunks.last?.lines.last, Line(kind: .context, text: "context line with some text to fill the row out", oldLine: 49_997, newLine: 49_997))
    }
}
