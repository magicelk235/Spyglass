import Foundation

/// One item directly inside a previewed folder.
public struct FolderEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case folder
        /// A folder Finder shows as one file: an app, an `.rtfd`, a bundle.
        case package
        case file
        case symlink
    }

    public var name: String
    public var kind: Kind
    /// A file's size in bytes; nil for folders, packages and links.
    public var size: UInt64?
    public var modified: Date?
    /// Finder's "Kind" text, such as "Folder" or "PNG image".
    public var typeDescription: String?

    public init(name: String, kind: Kind, size: UInt64? = nil, modified: Date? = nil, typeDescription: String? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.typeDescription = typeDescription
    }
}

public enum FolderListingError: Error, Equatable {
    /// The folder's contents can't be read: no permission, the sandbox
    /// refused, or it's gone.
    case unreadable
}

/// The visible items directly inside a folder, in Finder's order: folders
/// first, then everything else, each by name with numbers compared by value.
public struct FolderListing: Equatable, Sendable {
    public static let entryLimit = 5_000
    /// Items read before counting stops. Sorting needs every name, and a
    /// folder with a million files mustn't stall the preview.
    public static let scanLimit = 20_000

    /// At most the entry limit, cut after sorting.
    public var entries: [FolderEntry]
    /// Visible items in the folder, at most the scan limit.
    public var itemCount: Int
    /// Reading stopped at the scan limit or the time limit, so the folder
    /// holds more.
    public var itemCountIsLowerBound: Bool

    public var isTruncated: Bool { itemCountIsLowerBound || itemCount > entries.count }

    /// `seconds` bounds the reading on a slow disk or network volume; what
    /// was read by then is listed.
    public static func read(at url: URL, limit: Int = entryLimit, scanLimit: Int = scanLimit,
                            seconds: Double = 1.0) throws -> FolderListing {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(min(max(0, seconds) * 1e9, 1e18))
        let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isVolumeKey,
                                      .fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)
        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles],
            errorHandler: { _, _ in
                failed = true
                return true
            })
        else { throw FolderListingError.unreadable }

        var found: [Found] = []
        var lowerBound = false
        while let child = enumerator.nextObject() as? URL {
            // At least one item, so a slow disk still shows something.
            let outOfTime = !found.isEmpty && DispatchTime.now().uptimeNanoseconds > deadline
            guard found.count < scanLimit, !outOfTime else {
                lowerBound = true
                break
            }
            found.append(Found(url: child, values: try? child.resourceValues(forKeys: keySet)))
        }
        // An empty folder reads without complaint; a folder that can't be
        // opened reports an error and yields nothing.
        if found.isEmpty, failed { throw FolderListingError.unreadable }

        found.sort { inFinderOrder($0.entry, $1.entry) }
        var kept = Array(found.prefix(max(0, limit)))
        describeTypes(&kept)
        return FolderListing(entries: kept.map(\.entry), itemCount: found.count, itemCountIsLowerBound: lowerBound)
    }

    /// Visible items directly inside each named subfolder of `url`, the
    /// number Finder shows for a folder. Counted in the order given until
    /// `seconds` pass; folders that can't be read or aren't reached in time
    /// are left out.
    public static func itemCounts(in url: URL, folders: [String], seconds: Double = 0.5,
                                  isCancelled: () -> Bool = { false }) -> [String: Int] {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(min(max(0, seconds) * 1e9, 1e18))
        func outOfTime() -> Bool { DispatchTime.now().uptimeNanoseconds > deadline || isCancelled() }
        var counts: [String: Int] = [:]
        for name in folders {
            if outOfTime() { break }
            var failed = false
            guard let enumerator = FileManager.default.enumerator(
                at: url.appendingPathComponent(name, isDirectory: true), includingPropertiesForKeys: [],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles],
                errorHandler: { _, _ in
                    failed = true
                    return false
                })
            else { continue }
            var count = 0
            var finished = true
            while enumerator.nextObject() != nil {
                count += 1
                if count % 512 == 0, outOfTime() {
                    finished = false
                    break
                }
            }
            if finished, !failed { counts[name] = count }
        }
        return counts
    }

    /// Folders before everything else, then Finder's name comparison.
    public static func inFinderOrder(_ a: FolderEntry, _ b: FolderEntry) -> Bool {
        let aIsFolder = a.kind == .folder, bIsFolder = b.kind == .folder
        if aIsFolder != bIsFolder { return aIsFolder }
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.name < b.name
        }
    }

    private struct Found {
        var entry: FolderEntry
        let url: URL
        /// Items with the same key have the same type text; nil when it
        /// has to be looked up for this item alone.
        let typeKey: String?

        init(url: URL, values: URLResourceValues?) {
            self.url = url
            let kind: FolderEntry.Kind
            if values?.isSymbolicLink == true {
                kind = .symlink
            } else if values?.isDirectory == true {
                kind = values?.isPackage == true ? .package : .folder
            } else {
                kind = .file
            }
            let name = values?.name ?? url.lastPathComponent
            entry = FolderEntry(name: name, kind: kind,
                                size: kind == .file ? values?.fileSize.map { UInt64(max(0, $0)) } : nil,
                                modified: values?.contentModificationDate)
            let ext = (name as NSString).pathExtension.lowercased()
            switch kind {
            // A mount point reads as a volume, not a folder.
            case .folder: typeKey = values?.isVolume == true ? nil : "folder"
            case .package: typeKey = ext.isEmpty ? nil : "package." + ext
            // An extensionless file may be an executable, a script, or data.
            case .file: typeKey = ext.isEmpty ? nil : "file." + ext
            case .symlink: typeKey = nil
            }
        }
    }

    /// Looks up Finder's type text for the entries that will be shown.
    /// Asking Launch Services costs far more than reading a directory, so
    /// items that must share a type share one lookup.
    private static func describeTypes(_ items: inout [Found]) {
        var cache: [String: String?] = [:]
        for index in items.indices {
            if let key = items[index].typeKey, let cached = cache[key] {
                items[index].entry.typeDescription = cached
                continue
            }
            let description = (try? items[index].url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?
                .localizedTypeDescription
            items[index].entry.typeDescription = description
            if let key = items[index].typeKey { cache[key] = description }
        }
    }
}

/// How much a folder holds, counted by walking everything inside it, hidden
/// files and package contents included, under a time and item budget.
public struct FolderSize: Equatable, Sendable {
    public enum Total: Equatable, Sendable {
        case exact(UInt64)
        /// The walk stopped early or skipped unreadable folders.
        case atLeast(UInt64)
        /// Nothing could be counted.
        case unknown
    }

    public struct Budget: Sendable {
        public var seconds: Double
        public var items: Int

        public init(seconds: Double = 1.0, items: Int = 200_000) {
            self.seconds = seconds
            self.items = items
        }

        public static let standard = Budget()
    }

    /// Bytes of every regular file.
    public var total: Total
    /// Bytes inside each top-level folder or package, by name, for the ones
    /// the walk finished.
    public var childSizes: [String: UInt64]

    /// Walks `url` without following symbolic links or crossing onto other
    /// volumes. `isCancelled` is polled along the way.
    public static func measure(_ url: URL, budget: Budget = .standard,
                               isCancelled: () -> Bool = { false }) -> FolderSize {
        var walk = Walk(budget: budget)
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                walk.rootFailed = true
                return
            }
            walk.run(path, isCancelled: isCancelled)
        }
        return walk.result
    }

    private struct Walk {
        let budget: Budget
        let deadline: UInt64
        var bytes: UInt64 = 0
        var items = 0
        var complete = true
        var rootFailed = false
        var childSizes: [String: UInt64] = [:]
        /// The top-level folder being walked.
        var current: (name: String, bytes: UInt64, failed: Bool)?

        private static let nameOffset = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name)!

        init(budget: Budget) {
            self.budget = budget
            let nanoseconds = max(0, budget.seconds) * 1e9
            deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(min(nanoseconds, 1e18))
        }

        var result: FolderSize {
            let total: Total
            if rootFailed {
                total = .unknown
            } else if complete {
                total = .exact(bytes)
            } else {
                total = bytes > 0 ? .atLeast(bytes) : .unknown
            }
            return FolderSize(total: total, childSizes: childSizes)
        }

        mutating func run(_ path: UnsafePointer<CChar>, isCancelled: () -> Bool) {
            let paths: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: path), nil]
            // Physical: links are reported, never followed (the root itself
            // is, if it is one). XDEV: mounted volumes inside aren't entered.
            let options = FTS_PHYSICAL | FTS_COMFOLLOW | FTS_NOCHDIR | FTS_XDEV
            guard let fts = paths.withUnsafeBufferPointer({ fts_open($0.baseAddress, options, nil) }) else {
                rootFailed = true
                return
            }
            defer { fts_close(fts) }

            while let entry = fts_read(fts) {
                let info = Int32(entry.pointee.fts_info)
                let level = Int(entry.pointee.fts_level)
                switch info {
                case FTS_DP:
                    // Leaving a folder; a top-level one is now fully counted.
                    if level == 1, let folder = current {
                        if !folder.failed { childSizes[folder.name] = folder.bytes }
                        current = nil
                    }
                    continue
                case FTS_DNR, FTS_ERR, FTS_NS:
                    complete = false
                    if level == 0 {
                        rootFailed = true
                        return
                    }
                    if level == 1, info == FTS_DNR {
                        current = nil
                    } else if level > 1 {
                        current?.failed = true
                    }
                    continue
                case FTS_DC:
                    continue
                default:
                    break
                }

                if level > 0 {
                    items += 1
                    if info == FTS_F, let stat = entry.pointee.fts_statp {
                        let size = UInt64(max(0, stat.pointee.st_size))
                        bytes = Self.add(bytes, size)
                        if level > 1, current != nil { current!.bytes = Self.add(current!.bytes, size) }
                    }
                    if level == 1, info == FTS_D {
                        current = (Self.name(of: entry), 0, false)
                    }
                    if items >= budget.items {
                        complete = false
                        return
                    }
                }
                if info == FTS_D || items % 128 == 0,
                   DispatchTime.now().uptimeNanoseconds > deadline || isCancelled() {
                    complete = false
                    return
                }
            }
        }

        private static func name(of entry: UnsafeMutablePointer<FTSENT>) -> String {
            // fts_name is declared as a one-byte array; fts allocates the
            // entry with room for the whole name after it.
            let start = UnsafeRawPointer(entry).advanced(by: nameOffset).assumingMemoryBound(to: UInt8.self)
            return String(decoding: UnsafeBufferPointer(start: start, count: Int(entry.pointee.fts_namelen)), as: UTF8.self)
        }

        private static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
            let (sum, overflow) = a.addingReportingOverflow(b)
            return overflow ? .max : sum
        }
    }
}
