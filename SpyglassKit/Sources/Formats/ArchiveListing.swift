import Foundation

/// One item in an archive's table of contents.
public struct ArchiveEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file, directory, symlink, hardlink, other
    }

    /// Slash-separated path without a leading "/" or "./" or a trailing "/".
    public var path: String
    public var kind: Kind
    /// Uncompressed size in bytes.
    public var size: UInt64
    public var modified: Date?
    public var isEncrypted: Bool
    public var linkTarget: String?

    public init(path: String, kind: Kind, size: UInt64 = 0, modified: Date? = nil,
                isEncrypted: Bool = false, linkTarget: String? = nil) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.isEncrypted = isEncrypted
        self.linkTarget = linkTarget
    }

    /// Strips the decorations archivers put around paths: leading "/" and
    /// "./", trailing "/", and empty components. Returns "" for the archive
    /// root itself (a tar of ".").
    static func normalize(_ raw: String) -> String {
        if !raw.hasPrefix("/"), !raw.hasPrefix("./"), !raw.hasSuffix("/"), !raw.contains("//") {
            return raw
        }
        return raw.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .joined(separator: "/")
    }
}

/// What a reader found in an archive, and why the list may be partial.
public struct ArchiveListing: Sendable {
    public enum Incomplete: Equatable, Sendable {
        /// Stopped at the entry cap. `total` is the count the archive
        /// declares, when its format records one.
        case entryLimit(total: UInt64?)
        /// Stopped decompressing after this many bytes (byte or time cap).
        case workLimit(decompressedBytes: UInt64)
        /// The archive is cut short or corrupt after the listed entries.
        case damaged(String)
    }

    public var entries: [ArchiveEntry]
    public var incomplete: Incomplete?
    /// A `.gz` or `.bz2` holding one compressed file rather than a tarball.
    public var isSingleFile: Bool

    public init(entries: [ArchiveEntry], incomplete: Incomplete? = nil, isSingleFile: Bool = false) {
        self.entries = entries
        self.incomplete = incomplete
        self.isSingleFile = isSingleFile
    }
}

/// Caps on how much work listing one archive may do.
public struct ArchiveLimits: Sendable {
    public var maxEntries: Int
    /// Decompressed bytes a `.gz`/`.bz2` may produce before listing stops.
    public var maxDecompressedBytes: UInt64
    /// Seconds of decompression or reading before listing stops.
    public var maxDuration: TimeInterval

    public init(maxEntries: Int = 50_000, maxDecompressedBytes: UInt64 = 1 << 30,
                maxDuration: TimeInterval = 1.2) {
        self.maxEntries = maxEntries
        self.maxDecompressedBytes = maxDecompressedBytes
        self.maxDuration = maxDuration
    }

    public static let standard = ArchiveLimits()
}

public enum ArchiveError: Error, Equatable, CustomStringConvertible {
    /// The bytes aren't this format at all.
    case unrecognized(String)
    /// The file ends before the structure it declares.
    case truncated(String)
    /// A structure is present but inconsistent.
    case corrupt(String)
    /// Valid, but uses something this reader doesn't handle.
    case unsupported(String)
    /// Over a size cap.
    case tooLarge(String)

    public var description: String {
        switch self {
        case .unrecognized(let why), .truncated(let why), .corrupt(let why),
             .unsupported(let why), .tooLarge(let why):
            return why
        }
    }
}

/// Lists any archive Spyglass previews.
public enum ArchiveReader {

    /// `format` comes from the filename. The leading bytes win when they
    /// clearly name another format, so a gzip saved as `.tar` still lists.
    public static func list(_ url: URL, format: ArchiveFormat,
                            limits: ArchiveLimits = .standard) throws -> ArchiveListing {
        let head = try FileBytes(url: url).read(at: 0, count: 512)
        switch sniff(head) ?? format {
        case .zip:
            return try ZipReader(url: url, maxEntries: limits.maxEntries).listing
        case .tar:
            return try TarReader.list(url, limits: limits)
        case .gzip:
            return try CompressedArchive.list(url, format: .gzip, limits: limits)
        case .bzip2:
            return try CompressedArchive.list(url, format: .bzip2, limits: limits)
        }
    }

    static func sniff(_ head: [UInt8]) -> ArchiveFormat? {
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) || head.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            return .zip
        }
        if head.starts(with: [0x1F, 0x8B]) { return .gzip }
        if head.count >= 4, head.starts(with: [0x42, 0x5A, 0x68]), (0x31...0x39).contains(head[3]) {
            return .bzip2
        }
        if head.count >= 262, Array(head[257..<262]) == Array("ustar".utf8) { return .tar }
        return nil
    }
}
