import CryptoKit
import Foundation

/// What a `.torrent` file describes: its files, trackers, piece layout and
/// info hashes. Handles v1 (BEP 3), v2 (BEP 52) and hybrid torrents.
public struct TorrentInfo: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        /// Path components below the torrent's top folder (or just the file
        /// name in a single-file torrent).
        public var path: [String]
        public var length: UInt64

        public init(path: [String], length: UInt64) {
            self.path = path
            self.length = length
        }
    }

    public enum Version: Equatable, Sendable {
        case v1, v2
        /// A v1 piece list and a v2 file tree over the same files.
        case hybrid
    }

    public struct Tracker: Equatable, Sendable {
        public var url: String
        /// 1-based `announce-list` tier (BEP 12): clients try every
        /// tracker of a tier before moving to the next.
        public var tier: Int

        public init(url: String, tier: Int) {
            self.url = url
            self.tier = tier
        }
    }

    /// The suggested file or folder name; empty if the torrent has none.
    public var name: String
    /// Padding files (BEP 47) are left out.
    public var files: [File]
    public var isSingleFile: Bool
    public var totalSize: UInt64
    public var pieceLength: UInt64?
    public var pieceCount: Int?
    /// Every tier of `announce-list`, with `announce` leading the first tier
    /// if the list leaves it out. Each URL appears once.
    public var trackers: [Tracker]
    /// HTTP seeds from `url-list` (BEP 19).
    public var webSeeds: [String]
    public var creationDate: Date?
    public var createdBy: String?
    public var comment: String?
    public var isPrivate: Bool
    public var version: Version
    /// Hex SHA-1 of the bencoded info dictionary, for v1 and hybrid torrents.
    public var infoHashV1: String?
    /// Hex SHA-256 of the same bytes, for v2 and hybrid torrents.
    public var infoHashV2: String?
}

public enum TorrentError: Error, Equatable, CustomStringConvertible {
    case unreadable
    /// Valid bencode, but not shaped like a torrent.
    case notATorrent(String)
    /// A torrent field that is present but wrong.
    case malformed(String)

    public var description: String {
        switch self {
        case .unreadable: return "the file can't be read"
        case .notATorrent(let why), .malformed(let why): return why
        }
    }
}

extension TorrentInfo {

    public static func read(at url: URL, maxSize: Int = Bencode.Limits.standard.maxSize) throws -> TorrentInfo {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw TorrentError.unreadable }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maxSize + 1) ?? Data()
        } catch {
            throw TorrentError.unreadable
        }
        guard data.count <= maxSize else { throw BencodeError.tooLarge }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> TorrentInfo {
        let root = try Bencode.decode(data)
        guard case .dictionary = root else { throw TorrentError.notATorrent("the file isn't a dictionary") }
        guard let infoEntry = root.entry("info"), case .dictionary = infoEntry.value else {
            throw TorrentError.notATorrent("there is no info dictionary")
        }
        let info = infoEntry.value
        let decoder = TextDecoder(declared: root["encoding"]?.text)

        let name = decoder.text(info["name.utf-8"]) ?? decoder.text(info["name"]) ?? ""
        let pieceLength = info["piece length"]?.integer.flatMap { $0 > 0 ? UInt64($0) : nil }
        let pieces = info["pieces"]?.bytes
        if let pieces, pieces.count % 20 != 0 {
            throw TorrentError.malformed("the piece hashes aren't a whole number of SHA-1 digests")
        }
        let fileTree = info["file tree"]
        let isV2 = info["meta version"]?.integer == 2 || fileTree != nil
        let version: Version = isV2 ? (pieces == nil ? .v2 : .hybrid) : .v1

        var files: [File]
        var isSingleFile = false
        if let length = info["length"] {
            guard let bytes = length.integer, bytes >= 0 else { throw TorrentError.malformed("the file length is invalid") }
            files = [File(path: [name], length: UInt64(bytes))]
            isSingleFile = true
        } else if let list = info["files"] {
            guard let items = list.list else { throw TorrentError.malformed("the file list isn't a list") }
            files = try items.compactMap { try v1File($0, decoder: decoder) }
        } else if let fileTree {
            files = []
            v2Files(fileTree, prefix: [], decoder: decoder, into: &files)
            isSingleFile = files.count == 1 && files[0].path.count == 1
        } else {
            throw TorrentError.notATorrent("the info dictionary lists no files")
        }

        let totalSize = files.reduce(UInt64(0)) { total, file in
            let (sum, overflow) = total.addingReportingOverflow(file.length)
            return overflow ? .max : sum
        }
        var pieceCount: Int?
        if let pieces {
            pieceCount = pieces.count / 20
        } else if isV2, let pieceLength {
            // v2 pieces never span two files.
            pieceCount = files.reduce(0) { count, file in
                count &+ Int(clamping: file.length / pieceLength + (file.length % pieceLength == 0 ? 0 : 1))
            }
        }

        func url(_ value: BencodeValue?) -> String? {
            guard let text = decoder.text(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text
        }
        var trackers: [Tracker] = []
        var seenTrackers = Set<String>()
        for tier in root["announce-list"]?.list ?? [] {
            let number = (trackers.last?.tier ?? 0) + 1
            for tracker in tier.list ?? [] {
                guard let url = url(tracker), seenTrackers.insert(url).inserted else { continue }
                trackers.append(Tracker(url: url, tier: number))
            }
        }
        if let announce = url(root["announce"]), !seenTrackers.contains(announce) {
            trackers.insert(Tracker(url: announce, tier: 1), at: 0)
        }

        var webSeeds: [String] = []
        switch root["url-list"] {
        case .bytes?: webSeeds = [decoder.text(root["url-list"])].compactMap { $0 }.filter { !$0.isEmpty }
        case .list(let items)?: webSeeds = items.compactMap { decoder.text($0) }.filter { !$0.isEmpty }
        default: break
        }

        let infoBytes = data[(data.startIndex + infoEntry.range.lowerBound)..<(data.startIndex + infoEntry.range.upperBound)]
        return TorrentInfo(
            name: name,
            files: files,
            isSingleFile: isSingleFile,
            totalSize: totalSize,
            pieceLength: pieceLength,
            pieceCount: pieceCount,
            trackers: trackers,
            webSeeds: webSeeds,
            creationDate: root["creation date"]?.integer.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            createdBy: decoder.text(root["created by"]).flatMap { $0.isEmpty ? nil : $0 },
            comment: (decoder.text(root["comment.utf-8"]) ?? decoder.text(root["comment"])).flatMap { $0.isEmpty ? nil : $0 },
            isPrivate: info["private"]?.integer == 1,
            version: version,
            infoHashV1: version == .v2 ? nil : hex(Insecure.SHA1.hash(data: infoBytes)),
            infoHashV2: version == .v1 ? nil : hex(SHA256.hash(data: infoBytes)))
    }

    /// One entry of a v1 `files` list; nil for a padding file.
    private static func v1File(_ value: BencodeValue, decoder: TextDecoder) throws -> File? {
        guard case .dictionary = value else { throw TorrentError.malformed("a file entry isn't a dictionary") }
        guard let length = value["length"]?.integer, length >= 0 else {
            throw TorrentError.malformed("a file length is missing or invalid")
        }
        if let attributes = value["attr"]?.text, attributes.contains("p") { return nil }
        guard let components = (value["path.utf-8"] ?? value["path"])?.list, !components.isEmpty else {
            throw TorrentError.malformed("a file has no path")
        }
        let path = try components.map { component -> String in
            guard let text = decoder.text(component) else { throw TorrentError.malformed("a path component isn't text") }
            return text
        }
        return File(path: path, length: UInt64(length))
    }

    /// Files in a v2 `file tree`: a file is a dictionary holding an empty
    /// key whose value has the length; any other dictionary is a folder.
    /// Entries that fit neither are skipped. Bencode's depth cap bounds the
    /// recursion.
    private static func v2Files(_ node: BencodeValue, prefix: [String], decoder: TextDecoder, into files: inout [File]) {
        guard case .dictionary(let entries) = node else { return }
        for entry in entries where !entry.key.isEmpty {
            let path = prefix + [decoder.text(entry.key)]
            if let leaf = entry.value[""] {
                if let length = leaf["length"]?.integer, length >= 0 {
                    files.append(File(path: path, length: UInt64(length)))
                }
            } else {
                v2Files(entry.value, prefix: path, decoder: decoder, into: &files)
            }
        }
    }

    private static func hex<D: Digest>(_ digest: D) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(D.byteCount * 2)
        for byte in digest {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Torrent text is meant to be UTF-8; older ones use whatever their
    /// `encoding` field names. Text that is neither still shows, with
    /// replacement characters.
    private struct TextDecoder {
        let fallback: String.Encoding?

        init(declared name: String?) {
            fallback = name.flatMap { name in
                let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
                guard encoding != kCFStringEncodingInvalidId else { return nil }
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
            }
        }

        func text(_ value: BencodeValue?) -> String? {
            guard case .bytes(let bytes)? = value else { return nil }
            return text(bytes)
        }

        func text(_ bytes: Data) -> String {
            if let text = String(data: bytes, encoding: .utf8) { return text }
            if let fallback, let text = String(data: bytes, encoding: fallback) { return text }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
