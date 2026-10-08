import Foundation

/// A file or folder in an archive's tree.
public final class ArchiveNode {
    public let name: String
    public let kind: ArchiveEntry.Kind
    /// A file's size; for a folder, the total size of everything inside it.
    public fileprivate(set) var size: UInt64
    public fileprivate(set) var modified: Date?
    public fileprivate(set) var isEncrypted: Bool
    public fileprivate(set) var linkTarget: String?
    /// Sorted folders-first; empty for files.
    public fileprivate(set) var children: [ArchiveNode] = []
    /// Folders by name while the tree is being built.
    fileprivate var folders: [String: ArchiveNode]?

    public var isDirectory: Bool { kind == .directory }

    fileprivate init(name: String, kind: ArchiveEntry.Kind, size: UInt64 = 0, modified: Date? = nil,
                     isEncrypted: Bool = false, linkTarget: String? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.isEncrypted = isEncrypted
        self.linkTarget = linkTarget
        if kind == .directory { folders = [:] }
    }

    fileprivate func folder(named name: Substring) -> ArchiveNode {
        let key = String(name)
        if let existing = folders?[key] { return existing }
        let folder = ArchiveNode(name: key, kind: .directory)
        folders?[key] = folder
        children.append(folder)
        return folder
    }
}

/// An archive's flat list of paths rebuilt as folders and files. Folders
/// that only appear as part of a longer path are created along the way.
/// Built off the main thread, then read (and re-sorted) by one view.
public final class ArchiveTree: @unchecked Sendable {
    public enum SortKey: Sendable { case name, size, modified }

    public let root: ArchiveNode
    public let fileCount: Int
    public let folderCount: Int
    /// Uncompressed bytes of every file.
    public let totalSize: UInt64

    /// Levels past this fold into one node named by the rest of the path.
    /// Real archives stay far shallower; a hostile one could nest deeply
    /// enough to overflow the stack when the nodes are freed, which is
    /// recursive.
    static let maxDepth = 128

    public init(entries: [ArchiveEntry]) {
        let root = ArchiveNode(name: "", kind: .directory)
        var files = 0
        for entry in entries {
            var components = entry.path.split(separator: "/")
            if components.count > Self.maxDepth {
                let rest = components[(Self.maxDepth - 1)...].joined(separator: "/")
                components = Array(components[..<(Self.maxDepth - 1)]) + [Substring(rest)]
            }
            guard let last = components.popLast() else { continue }
            var parent = root
            for component in components {
                parent = parent.folder(named: component)
            }
            if entry.kind == .directory {
                let folder = parent.folder(named: last)
                folder.modified = entry.modified ?? folder.modified
            } else {
                files += 1
                parent.children.append(ArchiveNode(
                    name: String(last), kind: entry.kind, size: entry.size, modified: entry.modified,
                    isEncrypted: entry.isEncrypted, linkTarget: entry.linkTarget))
            }
        }

        // Folder totals bottom-up: parents before children in `folders`,
        // so walking it backwards sums every child before its parent.
        var folders: [ArchiveNode] = []
        var pending = [root]
        while let folder = pending.popLast() {
            folder.folders = nil
            folders.append(folder)
            pending.append(contentsOf: folder.children.lazy.filter(\.isDirectory))
        }
        for folder in folders.reversed() {
            folder.size = folder.children.reduce(0) { $0 &+ $1.size }
        }

        self.root = root
        self.fileCount = files
        self.folderCount = folders.count - 1
        self.totalSize = root.size
        sort(by: .name, ascending: true)
    }

    /// Re-sorts every folder, keeping folders above files.
    public func sort(by key: SortKey, ascending: Bool) {
        let ordered: (ArchiveNode, ArchiveNode) -> Bool
        switch key {
        case .name:
            ordered = { Self.compareNames($0.name, $1.name) < 0 }
        case .size:
            ordered = { $0.size != $1.size ? $0.size < $1.size : Self.compareNames($0.name, $1.name) < 0 }
        case .modified:
            ordered = {
                let a = $0.modified ?? .distantPast, b = $1.modified ?? .distantPast
                return a != b ? a < b : Self.compareNames($0.name, $1.name) < 0
            }
        }
        var pending = [root]
        while let folder = pending.popLast() {
            folder.children.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return ascending ? ordered(a, b) : ordered(b, a)
            }
            pending.append(contentsOf: folder.children.lazy.filter(\.isDirectory))
        }
    }

    /// Finder-like order: case-insensitive, with digit runs compared by
    /// value so "file2" sorts before "file10". Byte-level, because
    /// `localizedStandardCompare` is far too slow for 50,000 names.
    public static func compareNames(_ a: String, _ b: String) -> Int {
        var a = a, b = b
        return a.withUTF8 { x in b.withUTF8 { y in compare(x, y) } }
    }

    private static func compare(_ x: UnsafeBufferPointer<UInt8>, _ y: UnsafeBufferPointer<UInt8>) -> Int {
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        func lower(_ c: UInt8) -> UInt8 { c >= 0x41 && c <= 0x5A ? c | 0x20 : c }
        var i = 0, j = 0
        while i < x.count, j < y.count {
            if isDigit(x[i]), isDigit(y[j]) {
                var si = i, sj = j
                while si < x.count, x[si] == 0x30 { si += 1 }
                while sj < y.count, y[sj] == 0x30 { sj += 1 }
                var ei = si, ej = sj
                while ei < x.count, isDigit(x[ei]) { ei += 1 }
                while ej < y.count, isDigit(y[ej]) { ej += 1 }
                if ei - si != ej - sj { return ei - si < ej - sj ? -1 : 1 }
                for k in 0..<(ei - si) where x[si + k] != y[sj + k] {
                    return x[si + k] < y[sj + k] ? -1 : 1
                }
                i = ei
                j = ej
                continue
            }
            let a = lower(x[i]), b = lower(y[j])
            if a != b { return a < b ? -1 : 1 }
            i += 1
            j += 1
        }
        if x.count - i != y.count - j { return x.count - i < y.count - j ? -1 : 1 }
        // Equal ignoring case and leading zeros: fall back to raw bytes so
        // the order is still total.
        for k in 0..<min(x.count, y.count) where x[k] != y[k] {
            return x[k] < y[k] ? -1 : 1
        }
        return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
    }
}
