import XCTest
@testable import SpyglassKit

final class ArchiveTreeTests: XCTestCase {

    func testBuildsFoldersImpliedByPaths() {
        let stamp = Date(timeIntervalSince1970: 1_000)
        let tree = ArchiveTree(entries: [
            ArchiveEntry(path: "a/b/c.txt", kind: .file, size: 3),
            ArchiveEntry(path: "a/d.txt", kind: .file, size: 4),
            ArchiveEntry(path: "e", kind: .directory, modified: stamp),
            ArchiveEntry(path: "a", kind: .directory, modified: stamp),
        ])
        XCTAssertEqual(tree.root.children.map(\.name), ["a", "e"])
        let a = tree.root.children[0]
        XCTAssertEqual(a.children.map(\.name), ["b", "d.txt"])
        XCTAssertEqual(a.size, 7)
        XCTAssertEqual(a.modified, stamp, "an explicit entry after the implied folder still dates it")
        XCTAssertEqual(a.children[0].children.map(\.name), ["c.txt"])
        XCTAssertEqual(tree.fileCount, 2)
        XCTAssertEqual(tree.folderCount, 3)
        XCTAssertEqual(tree.totalSize, 7)
    }

    func testFoldersComeFirstThenNaturalOrder() {
        let names = ["file10", "file2", "File1", "zeta/x", "Alpha", "file02b"]
        let tree = ArchiveTree(entries: names.map { ArchiveEntry(path: $0, kind: .file, size: 1) })
        XCTAssertEqual(tree.root.children.map(\.name), ["zeta", "Alpha", "File1", "file2", "file02b", "file10"])
    }

    func testSortsBySizeAndDateKeepingFoldersFirst() {
        let tree = ArchiveTree(entries: [
            ArchiveEntry(path: "small", kind: .file, size: 1, modified: Date(timeIntervalSince1970: 300)),
            ArchiveEntry(path: "big", kind: .file, size: 100, modified: Date(timeIntervalSince1970: 100)),
            ArchiveEntry(path: "dir/inner", kind: .file, size: 5),
            ArchiveEntry(path: "middle", kind: .file, size: 10, modified: Date(timeIntervalSince1970: 200)),
        ])
        tree.sort(by: .size, ascending: false)
        XCTAssertEqual(tree.root.children.map(\.name), ["dir", "big", "middle", "small"])
        tree.sort(by: .modified, ascending: true)
        XCTAssertEqual(tree.root.children.map(\.name), ["dir", "big", "middle", "small"])
        tree.sort(by: .modified, ascending: false)
        XCTAssertEqual(tree.root.children.map(\.name), ["dir", "small", "middle", "big"])
    }

    func testVeryDeepPathsFoldWithoutLosingTheirPath() {
        let deep = Array(repeating: "d", count: 20_000).joined(separator: "/") + "/leaf"
        let tree = ArchiveTree(entries: [ArchiveEntry(path: deep, kind: .file, size: 9)])
        var names: [String] = []
        var node = tree.root
        while let only = node.children.first {
            names.append(only.name)
            node = only
        }
        XCTAssertEqual(names.joined(separator: "/"), deep)
        XCTAssertLessThan(names.count, 1000)
        XCTAssertEqual(node.kind, .file)
        XCTAssertEqual(tree.root.size, 9)
    }

    func testNaturalComparison() {
        XCTAssertLessThan(ArchiveTree.compareNames("img9.png", "img10.png"), 0)
        XCTAssertLessThan(ArchiveTree.compareNames("abc", "ABD"), 0)
        XCTAssertLessThan(ArchiveTree.compareNames("abc", "abcd"), 0)
        XCTAssertEqual(ArchiveTree.compareNames("same", "same"), 0)
        XCTAssertNotEqual(ArchiveTree.compareNames("Same", "same"), 0, "the order stays total")
    }
}
