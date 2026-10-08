import XCTest
@testable import SpyglassKit

final class PreviewKindTests: XCTestCase {

    func testRoutesByExtension() {
        let cases: [(String, PreviewKind)] = [
            ("Notes.gdoc", .googleStub),
            ("link.webloc", .webloc),
            ("README.md", .markdown),
            ("post.MDX", .markdown),
            ("main.swift", .code(language: "swift")),
            ("app.tsx", .code(language: "typescript")),
            ("data.json", .structured(.json)),
            ("Info.plist", .structured(.plist)),
            ("ci.yml", .structured(.yaml)),
            ("Cargo.toml", .structured(.toml)),
            ("feed.xml", .structured(.xml)),
            ("fix.patch", .diff),
            ("fix.diff", .diff),
            ("export.tsv", .table(separator: "\t")),
            ("app.sqlite3", .sqlite),
            ("cache.db", .sqlite),
            ("src.zip", .archive(.zip)),
            ("src.tar", .archive(.tar)),
            ("src.tgz", .archive(.gzip)),
            ("src.tar.gz", .archive(.gzip)),
            ("dump.sql.gz", .archive(.gzip)),
            ("src.tar.bz2", .archive(.bzip2)),
            ("Safari.app", .bundle(.app)),
            ("Game.ipa", .bundle(.ipa)),
            ("Install.pkg", .bundle(.pkg)),
            ("Disk.dmg", .bundle(.dmg)),
        ]
        for (name, kind) in cases {
            XCTAssertEqual(PreviewKind.route(filename: name, uti: nil), kind, name)
        }
    }

    func testExtensionlessBuildFilesRouteAsCode() {
        XCTAssertEqual(PreviewKind.route(filename: "Makefile", uti: nil), .code(language: "makefile"))
        XCTAssertEqual(PreviewKind.route(filename: "GNUmakefile", uti: nil), .code(language: "makefile"))
        XCTAssertEqual(PreviewKind.route(filename: "nginx.conf", uti: nil), .code(language: "nginx"))
    }

    func testExtensionWinsOverUTI() {
        // A .json file LaunchServices typed as plain source code still gets the
        // pretty-printer: the router and the claim list never disagree.
        XCTAssertEqual(PreviewKind.route(filename: "a.json", uti: "public.source-code"), .structured(.json))
    }

    func testRenamedSourceFileRoutesByItsUTI() {
        XCTAssertEqual(PreviewKind.route(filename: "thing.weird", uti: "public.shell-script"), .code(language: "bash"))
        XCTAssertEqual(PreviewKind.route(filename: "thing.weird", uti: "com.spyglass.source.kotlin"), .code(language: "kotlin"))
    }

    func testPlainTextAndUnknownFilesAreUnrouted() {
        XCTAssertNil(PreviewKind.route(filename: "notes.txt", uti: "public.plain-text"))
        XCTAssertNil(PreviewKind.route(filename: "photo.heic", uti: "public.heic"))
        XCTAssertNil(PreviewKind.route(filename: "noextension", uti: nil))
    }

    func testGroupsCoverEveryFormatKind() {
        XCTAssertNil(PreviewKind.googleStub.group)
        XCTAssertNil(PreviewKind.webloc.group)
        XCTAssertEqual(PreviewKind.code(language: nil).group, .code)
        XCTAssertEqual(PreviewKind.archive(.bzip2).group, .archive)
        XCTAssertEqual(PreviewKind.bundle(.dmg).group, .bundle)
    }

    /// Every type the extension claims in Info.plist must route somewhere,
    /// otherwise Quick Look hands Spyglass a file it then can't place.
    func testEveryClaimedUTIRoutes() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Preview/Info.plist")
        let root = try XCTUnwrap(NSDictionary(contentsOf: plist))
        let ext = try XCTUnwrap(root["NSExtension"] as? [String: Any])
        let attrs = try XCTUnwrap(ext["NSExtensionAttributes"] as? [String: Any])
        let utis = try XCTUnwrap(attrs["QLSupportedContentTypes"] as? [String])
        XCTAssertGreaterThan(utis.count, 10)
        for uti in utis {
            XCTAssertNotNil(PreviewKind.route(filename: "untitled", uti: uti), "claimed but unrouted: \(uti)")
        }
    }
}
