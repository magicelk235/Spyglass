import Foundation

/// Lists a tar file by reading only its headers; member data is skipped
/// with seeks, so a huge tarball with few members lists instantly.
public enum TarReader {

    public static func list(_ url: URL, limits: ArchiveLimits = .standard) throws -> ArchiveListing {
        let file = try FileBytes(url: url)
        var parser = TarParser(maxEntries: limits.maxEntries)
        let deadline = monotonicSeconds() + limits.maxDuration
        var offset: UInt64 = 0
        var outOfTime = false
        do {
            while !parser.isFinished {
                if parser.skipRemaining > 0 {
                    let jump = min(parser.skipRemaining, file.size - offset)
                    if jump == 0 { break }
                    parser.skip(jump)
                    offset += jump
                    continue
                }
                if monotonicSeconds() > deadline {
                    outOfTime = true
                    break
                }
                let chunk = try file.read(at: offset, count: 64 * 1024)
                if chunk.isEmpty { break }
                try chunk.withUnsafeBytes { try parser.feed($0) }
                offset += UInt64(chunk.count)
            }
        } catch let error as ArchiveError {
            return try parser.listing(failure: error)
        }
        if outOfTime {
            return parser.listing(incomplete: .workLimit(decompressedBytes: offset))
        }
        return try parser.listingAtEndOfInput()
    }
}

/// An incremental tar parser: feed it the archive's bytes in order, in
/// chunks of any size. Understands ustar, GNU (`L`/`K` long names, old
/// sparse files, base-256 numbers) and pax (`path`, `linkpath`, `size`,
/// `mtime`) headers.
struct TarParser {
    private(set) var entries: [ArchiveEntry] = []
    /// An end-of-archive block was seen, or the entry cap was reached.
    private(set) var isFinished = false
    private(set) var hitEntryLimit = false
    /// Member data still to pass over. A reader with random access may jump
    /// it with `skip(_:)` instead of feeding the bytes.
    private(set) var skipRemaining: UInt64 = 0

    private let maxEntries: Int
    private var block: [UInt8] = []
    private var capture: Capture?
    private var sparseExtensionsThenSkip: UInt64?
    // Metadata the extension headers set for the next real entry.
    private var longName: String?
    private var longLink: String?
    private var pax: [String: String] = [:]

    private struct Capture {
        enum Target { case longName, longLink, pax }
        var target: Target
        var data: [UInt8] = []
        var remaining: UInt64
        var padding: UInt64
        var cap: Int
    }

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
        block.reserveCapacity(512)
    }

    /// True when `block` (512 bytes) is a tar header: the `ustar` magic, or
    /// for pre-POSIX archives, a checksum that adds up.
    static func looksLikeHeader(_ block: [UInt8]) -> Bool {
        guard block.count >= 512 else { return false }
        if Array(block[257..<262]) == Array("ustar".utf8) { return true }
        return block.withUnsafeBytes { checksumMatches(UnsafeRawBufferPointer(rebasing: $0[0..<512])) }
    }

    mutating func skip(_ count: UInt64) {
        skipRemaining -= min(count, skipRemaining)
    }

    mutating func feed(_ bytes: UnsafeRawBufferPointer) throws {
        var index = 0
        while index < bytes.count, !isFinished {
            let available = bytes.count - index
            if skipRemaining > 0 {
                let count = Int(min(skipRemaining, UInt64(available)))
                skipRemaining -= UInt64(count)
                index += count
                continue
            }
            if var current = capture {
                let count = Int(min(current.remaining, UInt64(available)))
                let room = max(0, current.cap - current.data.count)
                current.data.append(contentsOf: bytes[index..<(index + min(count, room))])
                current.remaining -= UInt64(count)
                index += count
                if current.remaining == 0 {
                    finishCapture(current)
                    skipRemaining = current.padding
                    capture = nil
                } else {
                    capture = current
                }
                continue
            }
            if block.isEmpty, available >= 512 {
                try handle(UnsafeRawBufferPointer(rebasing: bytes[index..<(index + 512)]))
                index += 512
                continue
            }
            let count = min(512 - block.count, available)
            block.append(contentsOf: bytes[index..<(index + count)])
            index += count
            if block.count == 512 {
                let header = block
                block.removeAll(keepingCapacity: true)
                try header.withUnsafeBytes { try handle($0) }
            }
        }
    }

    // MARK: - Results

    /// The listing once the input has run out.
    func listingAtEndOfInput() throws -> ArchiveListing {
        if isFinished {
            return listing(incomplete: hitEntryLimit ? .entryLimit(total: nil) : nil)
        }
        // Running out exactly between members is how some writers end an
        // archive; running out inside one means the file is cut short.
        if block.isEmpty, capture == nil, skipRemaining == 0, sparseExtensionsThenSkip == nil {
            if entries.isEmpty, longName == nil, pax.isEmpty {
                throw ArchiveError.truncated("The tar archive is empty")
            }
            return listing(incomplete: nil)
        }
        return try listing(failure: .truncated("The tar archive is cut short"))
    }

    /// Keeps whatever was listed before a failure; with nothing listed the
    /// failure is the result.
    func listing(failure: ArchiveError) throws -> ArchiveListing {
        guard !entries.isEmpty else { throw failure }
        return listing(incomplete: .damaged(failure.description))
    }

    func listing(incomplete: ArchiveListing.Incomplete?) -> ArchiveListing {
        ArchiveListing(entries: entries, incomplete: incomplete)
    }

    // MARK: - Headers

    private mutating func handle(_ header: UnsafeRawBufferPointer) throws {
        if let dataSize = sparseExtensionsThenSkip {
            // Old GNU sparse files continue their map in extension blocks
            // that carry no checksum; byte 504 says whether another follows.
            if header[504] == 0 {
                sparseExtensionsThenSkip = nil
                skipRemaining = try padded(dataSize)
            }
            return
        }
        if !header.contains(where: { $0 != 0 }) {
            isFinished = true
            return
        }
        guard Self.checksumMatches(header) else {
            throw ArchiveError.corrupt("A tar header fails its checksum")
        }

        let type = header[156]
        let isPOSIX = header[257..<263].elementsEqual("ustar\0".utf8)
        guard let headerSize = Self.number(header, 124, 12) else {
            throw ArchiveError.corrupt("A tar header has an unreadable size")
        }

        // Extension headers carry their own size; only the member they
        // describe takes a pax `size` override.
        switch type {
        case UInt8(ascii: "L"):
            try startCapture(.longName, size: headerSize, cap: 64 * 1024)
            return
        case UInt8(ascii: "K"):
            try startCapture(.longLink, size: headerSize, cap: 64 * 1024)
            return
        case UInt8(ascii: "x"), UInt8(ascii: "X"):
            try startCapture(.pax, size: headerSize, cap: 1 << 20)
            return
        default:
            break
        }
        let dataSize = pax["size"].flatMap { UInt64($0) } ?? headerSize

        var name = longName ?? pax["GNU.sparse.name"] ?? pax["path"] ?? Self.string(header, 0, 100)
        if longName == nil, pax["path"] == nil, pax["GNU.sparse.name"] == nil, isPOSIX {
            let prefix = Self.string(header, 345, 155)
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        let link = longLink ?? pax["linkpath"] ?? Self.string(header, 157, 100)
        // Writers that record no time leave zero; that's "unknown", not 1970.
        let modified = (pax["mtime"].flatMap { Double($0) } ?? Self.number(header, 136, 12).map { Double($0) })
            .flatMap { $0 == 0 ? nil : Date(timeIntervalSince1970: $0) }

        var kind: ArchiveEntry.Kind
        var size = dataSize
        var skip = dataSize
        var listed = true
        switch type {
        case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
            kind = name.hasSuffix("/") ? .directory : .file
            if kind == .directory { size = 0 }
        case UInt8(ascii: "1"):
            // A hard link's data lives with the file it links to, unless a
            // pax header explicitly gives it a size.
            kind = .hardlink
            if pax["size"] == nil { size = 0; skip = 0 }
        case UInt8(ascii: "2"):
            kind = .symlink
            size = 0; skip = 0
        case UInt8(ascii: "3"), UInt8(ascii: "4"), UInt8(ascii: "6"):
            kind = .other
            size = 0; skip = 0
        case UInt8(ascii: "5"):
            kind = .directory
            size = 0; skip = 0
        case UInt8(ascii: "D"):
            // GNU dumpdir: a directory whose data lists its contents.
            kind = .directory
            size = 0
        case UInt8(ascii: "S"):
            kind = .file
            size = pax["GNU.sparse.realsize"].flatMap { UInt64($0) }
                ?? Self.number(header, 483, 12) ?? dataSize
            if header[482] != 0 {
                sparseExtensionsThenSkip = dataSize
                skip = 0
            }
        case UInt8(ascii: "A")...UInt8(ascii: "Z"):
            // Vendor metadata (volume labels, continuation records):
            // not a member of its own.
            kind = .other
            listed = false
        default:
            // POSIX: an unknown type is read as a regular file.
            kind = .file
        }
        if let real = pax["GNU.sparse.realsize"] ?? pax["GNU.sparse.size"], let value = UInt64(real), kind == .file {
            size = value
        }

        longName = nil
        longLink = nil
        pax.removeAll()
        if sparseExtensionsThenSkip == nil {
            skipRemaining = try padded(skip)
        }

        let path = ArchiveEntry.normalize(name)
        guard listed, !path.isEmpty else { return }
        guard entries.count < maxEntries else {
            hitEntryLimit = true
            isFinished = true
            return
        }
        entries.append(ArchiveEntry(
            path: path, kind: kind, size: size,
            modified: modified,
            linkTarget: kind == .symlink || kind == .hardlink ? link : nil))
    }

    private mutating func startCapture(_ target: Capture.Target, size: UInt64, cap: Int) throws {
        let padding = try padded(size) - size
        if size == 0 {
            finishCapture(Capture(target: target, remaining: 0, padding: 0, cap: cap))
            return
        }
        capture = Capture(target: target, remaining: size, padding: padding, cap: cap)
    }

    private mutating func finishCapture(_ done: Capture) {
        switch done.target {
        case .longName:
            longName = Self.cString(done.data)
        case .longLink:
            longLink = Self.cString(done.data)
        case .pax:
            Self.parsePax(done.data, into: &pax)
        }
    }

    private func padded(_ size: UInt64) throws -> UInt64 {
        guard size <= UInt64(Int64.max) - 511 else {
            throw ArchiveError.corrupt("A tar member declares an impossible size")
        }
        return (size + 511) & ~511
    }

    // MARK: - Fields

    /// The stored checksum against the header's byte sum with the checksum
    /// field read as spaces. Some old writers summed signed bytes.
    static func checksumMatches(_ header: UnsafeRawBufferPointer) -> Bool {
        guard let stored = number(header, 148, 8) else { return false }
        var unsigned = 0
        var signed = 0
        for (index, byte) in header.enumerated() {
            let value = (148..<156).contains(index) ? 0x20 : byte
            unsigned += Int(value)
            signed += Int(Int8(bitPattern: value))
        }
        return stored == UInt64(unsigned) || Int64(clamping: stored) == Int64(signed)
    }

    /// A numeric field: octal text (space or NUL terminated), or GNU
    /// base-256 when the high bit of the first byte is set. nil when the
    /// field is malformed or negative.
    static func number(_ header: UnsafeRawBufferPointer, _ offset: Int, _ length: Int) -> UInt64? {
        let field = UnsafeRawBufferPointer(rebasing: header[offset..<(offset + length)])
        guard let first = field.first else { return nil }
        if first & 0x80 != 0 {
            guard first & 0x40 == 0 else { return nil }   // negative
            var value = UInt64(first & 0x3F)
            for byte in field.dropFirst() {
                guard value >> 55 == 0 else { return nil }
                value = value << 8 | UInt64(byte)
            }
            return value
        }
        var value: UInt64 = 0
        var index = 0
        while index < field.count, field[index] == 0x20 { index += 1 }
        var digits = 0
        while index < field.count {
            let byte = field[index]
            if byte == 0 || byte == 0x20 { break }
            guard (0x30...0x37).contains(byte), value >> 60 == 0 else { return nil }
            value = value << 3 | UInt64(byte - 0x30)
            digits += 1
            index += 1
        }
        // Only padding may follow the digits.
        while index < field.count {
            guard field[index] == 0 || field[index] == 0x20 else { return nil }
            index += 1
        }
        return value
    }

    /// A NUL-terminated text field. Names are bytes in tar; nearly every
    /// writer today uses UTF-8, and anything else decodes with replacement
    /// characters rather than failing.
    static func string(_ header: UnsafeRawBufferPointer, _ offset: Int, _ length: Int) -> String {
        let field = UnsafeRawBufferPointer(rebasing: header[offset..<(offset + length)])
        let end = field.firstIndex(of: 0) ?? field.count
        return String(decoding: UnsafeRawBufferPointer(rebasing: field[0..<end]), as: UTF8.self)
    }

    static func cString(_ bytes: [UInt8]) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[0..<end], as: UTF8.self)
    }

    /// pax records are "<length> <key>=<value>\n", where length counts the
    /// whole record. Parsing stops at the first malformed record.
    static func parsePax(_ data: [UInt8], into attributes: inout [String: String]) {
        var start = 0
        while start < data.count {
            var index = start
            var length = 0
            while index < data.count, (0x30...0x39).contains(data[index]), length < 1 << 30 {
                length = length * 10 + Int(data[index] - 0x30)
                index += 1
            }
            guard index > start, index < data.count, data[index] == 0x20,
                  length > index - start + 1, length <= data.count - start else { return }
            let end = start + length
            guard data[end - 1] == 0x0A,
                  let equals = data[(index + 1)..<(end - 1)].firstIndex(of: 0x3D) else { return }
            let key = String(decoding: data[(index + 1)..<equals], as: UTF8.self)
            let value = String(decoding: data[(equals + 1)..<(end - 1)], as: UTF8.self)
            attributes[key] = value
            start = end
        }
    }
}
