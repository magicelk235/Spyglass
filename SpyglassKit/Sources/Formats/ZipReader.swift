import Foundation
import zlib

/// One member of a ZIP archive, as its central-directory record describes it.
public struct ZipEntry: Equatable, Sendable {
    public var path: String
    public var compressedSize: UInt64
    public var uncompressedSize: UInt64
    public var modified: Date?
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var isEncrypted: Bool
    /// 0 stored, 8 deflate; anything else can be listed but not read.
    public var method: UInt16
    public var crc32: UInt32
    var localHeaderOffset: UInt64

    public var archiveEntry: ArchiveEntry {
        ArchiveEntry(path: path,
                     kind: isDirectory ? .directory : isSymlink ? .symlink : .file,
                     size: isDirectory ? 0 : uncompressedSize,
                     modified: modified,
                     isEncrypted: isEncrypted)
    }
}

/// Reads a ZIP archive's central directory (including ZIP64), and on request
/// one member's bytes. Never reads the member data it doesn't need.
public final class ZipReader {
    public static let defaultEntryLimit = 50_000
    /// The most central directory read in one go; past this the listing
    /// stops early, as it does at the entry limit.
    static let maxCentralDirectoryBytes = 32 << 20

    public let entries: [ZipEntry]
    /// The entry count the archive declares.
    public let declaredEntryCount: UInt64
    /// True when the listing stopped at the entry limit with records left.
    public let hitEntryLimit: Bool
    /// Why the central directory stops early, when part of it is unreadable.
    public let damage: String?

    private let file: FileBytes
    /// Bytes prepended to the archive (a self-extractor stub) that the
    /// recorded offsets don't account for.
    private let shift: UInt64
    /// Where the central directory starts in the file. An APK keeps its
    /// signing block right before it.
    let directoryStart: UInt64

    public init(url: URL, maxEntries: Int = defaultEntryLimit) throws {
        file = try FileBytes(url: url)
        let end = try Self.findEnd(in: file)
        let directory = try Self.locateDirectory(end, in: file)
        shift = directory.shift
        directoryStart = directory.start
        declaredEntryCount = end.totalEntries

        let readLength = Int(min(end.directorySize, UInt64(Self.maxCentralDirectoryBytes)))
        let capped = end.directorySize > UInt64(readLength)
        let bytes = try file.readExactly(at: directory.start, count: readLength, "central directory")

        var entries: [ZipEntry] = []
        entries.reserveCapacity(min(Int(clamping: end.totalEntries), maxEntries))
        var dates = DosDateConverter()
        var damage: String?
        var hitLimit = false
        bytes.withUnsafeBytes { buffer in
            var cursor = ByteCursor(buffer)
            while cursor.remaining > 0 {
                if entries.count >= maxEntries {
                    hitLimit = true
                    break
                }
                do {
                    if let entry = try Self.readRecord(&cursor, dates: &dates) {
                        entries.append(entry)
                    }
                } catch {
                    // A record cut by the read cap just ends the listing.
                    if capped { hitLimit = true } else { damage = "The central directory is damaged" }
                    break
                }
            }
        }
        if entries.isEmpty, let damage { throw ArchiveError.corrupt(damage) }
        self.entries = entries
        self.hitEntryLimit = hitLimit
        self.damage = damage
    }

    public var listing: ArchiveListing {
        var incomplete: ArchiveListing.Incomplete?
        if hitEntryLimit {
            incomplete = .entryLimit(total: declaredEntryCount > UInt64(entries.count) ? declaredEntryCount : nil)
        } else if let damage {
            incomplete = .damaged(damage)
        }
        return ArchiveListing(entries: entries.map(\.archiveEntry), incomplete: incomplete)
    }

    /// The whole member, refusing anything that inflates past `maxSize`.
    /// Checks the CRC, so a damaged member throws instead of returning junk.
    public func contents(of entry: ZipEntry, maxSize: Int) throws -> Data {
        guard entry.uncompressedSize <= UInt64(maxSize) else {
            throw ArchiveError.tooLarge("\(entry.path) is larger than \(maxSize) bytes")
        }
        let data = try read(entry, limit: maxSize, wholeMember: true)
        let crc = data.withUnsafeBytes { buffer -> UInt32 in
            UInt32(zlib.crc32(0, buffer.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(buffer.count)))
        }
        guard crc == entry.crc32 else { throw ArchiveError.corrupt("\(entry.path) fails its checksum") }
        return data
    }

    /// At most the first `length` bytes of the member: enough to sniff a
    /// header without inflating the rest.
    public func prefix(of entry: ZipEntry, length: Int) throws -> Data {
        try read(entry, limit: length, wholeMember: false)
    }

    /// Bytes of the archive file itself, for structures outside any member.
    func rawBytes(at offset: UInt64, count: Int) throws -> [UInt8] {
        try file.read(at: offset, count: count)
    }

    // MARK: - End of central directory

    private struct End {
        var position: UInt64
        var totalEntries: UInt64
        var directorySize: UInt64
        var directoryOffset: UInt64
        /// Where the ZIP64 end record sits, when there is one.
        var zip64Position: UInt64?
    }

    private static func findEnd(in file: FileBytes) throws -> End {
        let fixed = 22
        guard file.size >= UInt64(fixed) else { throw ArchiveError.unrecognized("Not a ZIP archive") }
        let tailLength = Int(min(file.size, UInt64(fixed + 0xFFFF)))
        let tailStart = file.size - UInt64(tailLength)
        let tail = try file.readExactly(at: tailStart, count: tailLength, "archive")

        // The comment length must reach exactly to the end of the file;
        // failing that, accept the last record whose comment fits (some
        // tools append junk after the archive).
        var exact: Int?
        var loose: Int?
        var index = tailLength - fixed
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B, tail[index + 2] == 0x05, tail[index + 3] == 0x06 {
                let commentLength = Int(tail[index + 20]) | Int(tail[index + 21]) << 8
                if index + fixed + commentLength == tailLength { exact = index; break }
                if loose == nil, index + fixed + commentLength <= tailLength { loose = index }
            }
            index -= 1
        }
        guard let found = exact ?? loose else {
            let head = try file.read(at: 0, count: 4)
            if head == [0x50, 0x4B, 0x03, 0x04] {
                throw ArchiveError.truncated("The ZIP archive is cut short: its central directory is missing")
            }
            throw ArchiveError.unrecognized("Not a ZIP archive")
        }

        var end = try tail.withUnsafeBytes { buffer -> End in
            var cursor = ByteCursor(buffer, offset: found + 8)
            _ = try cursor.u16le()                      // entries on this disk
            let total = try cursor.u16le()
            let size = try cursor.u32le()
            let offset = try cursor.u32le()
            return End(position: tailStart + UInt64(found), totalEntries: UInt64(total),
                       directorySize: UInt64(size), directoryOffset: UInt64(offset))
        }
        if let zip64 = try readZip64End(before: end.position, in: file) {
            end.totalEntries = zip64.total
            end.directorySize = zip64.size
            end.directoryOffset = zip64.offset
            end.zip64Position = zip64.position
        }
        return end
    }

    /// The ZIP64 end record, found through the locator that sits right
    /// before the classic end record.
    private static func readZip64End(before endPosition: UInt64, in file: FileBytes)
        throws -> (position: UInt64, total: UInt64, size: UInt64, offset: UInt64)? {
        guard endPosition >= 20 else { return nil }
        let locator = try file.readExactly(at: endPosition - 20, count: 20, "ZIP64 locator")
        guard locator.starts(with: [0x50, 0x4B, 0x06, 0x07]) else { return nil }
        let recorded = locator.withUnsafeBytes { buffer -> UInt64 in
            var cursor = ByteCursor(buffer, offset: 8)
            return (try? cursor.u64le()) ?? 0
        }
        // The recorded offset ignores any prepended stub; the record
        // normally sits directly before the locator, so try there too.
        var candidates = [recorded]
        if endPosition >= 20 + 56 { candidates.append(endPosition - 20 - 56) }
        for position in candidates where position < endPosition {
            let record = try file.read(at: position, count: 56)
            guard record.count == 56, record.starts(with: [0x50, 0x4B, 0x06, 0x06]) else { continue }
            return try record.withUnsafeBytes { buffer in
                var cursor = ByteCursor(buffer, offset: 32)
                let total = try cursor.u64le()
                let size = try cursor.u64le()
                let offset = try cursor.u64le()
                return (position, total, size, offset)
            }
        }
        throw ArchiveError.corrupt("The ZIP64 end record is missing")
    }

    /// Where the central directory really starts. Normally at the recorded
    /// offset; in a self-extractor, everything is shifted by the stub's size.
    private static func locateDirectory(_ end: End, in file: FileBytes) throws -> (start: UInt64, shift: UInt64) {
        let limit = end.zip64Position ?? end.position
        guard end.directorySize <= limit else { throw ArchiveError.corrupt("The central directory size is impossible") }
        let expected = limit - end.directorySize
        if end.directorySize == 0 { return (expected, expected >= end.directoryOffset ? expected - end.directoryOffset : 0) }
        let signature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        if end.directoryOffset < limit, try file.read(at: end.directoryOffset, count: 4) == signature {
            return (end.directoryOffset, 0)
        }
        if expected > end.directoryOffset, try file.read(at: expected, count: 4) == signature {
            return (expected, expected - end.directoryOffset)
        }
        throw ArchiveError.corrupt("The central directory isn't where the archive says")
    }

    // MARK: - Central directory records

    private static func readRecord(_ cursor: inout ByteCursor, dates: inout DosDateConverter) throws -> ZipEntry? {
        guard try cursor.u32le() == 0x0201_4B50 else {
            throw ArchiveError.corrupt("Bad central directory record")
        }
        let madeBy = try cursor.u16le()
        _ = try cursor.u16le()                          // version needed
        let flags = try cursor.u16le()
        let method = try cursor.u16le()
        let dosTime = try cursor.u16le()
        let dosDate = try cursor.u16le()
        let crc = try cursor.u32le()
        var compressed = UInt64(try cursor.u32le())
        var uncompressed = UInt64(try cursor.u32le())
        let nameLength = Int(try cursor.u16le())
        let extraLength = Int(try cursor.u16le())
        let commentLength = Int(try cursor.u16le())
        _ = try cursor.u16le()                          // disk number start
        _ = try cursor.u16le()                          // internal attributes
        let external = try cursor.u32le()
        var localOffset = UInt64(try cursor.u32le())
        let rawName = try cursor.bytes(nameLength)
        let extra = try cursor.bytes(extraLength)
        try cursor.skip(commentLength)

        var modified = dates.date(dosDate: dosDate, dosTime: dosTime)
        var unicodeName: String?
        var fields = ByteCursor(extra)
        while fields.remaining >= 4 {
            let id = try fields.u16le()
            let size = Int(try fields.u16le())
            guard let data = try? fields.bytes(size) else { break }
            var field = ByteCursor(data)
            switch id {
            case 0x0001:
                // ZIP64: only the fields saturated in the fixed record, in order.
                if uncompressed == 0xFFFF_FFFF, let value = try? field.u64le() { uncompressed = value }
                if compressed == 0xFFFF_FFFF, let value = try? field.u64le() { compressed = value }
                if localOffset == 0xFFFF_FFFF, let value = try? field.u64le() { localOffset = value }
            case 0x5455:
                // Extended timestamp: flag byte, then UTC mtime when bit 0 is set.
                if let flags = try? field.u8(), flags & 1 != 0, let time = try? field.u32le() {
                    modified = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: time)))
                }
            case 0x7075:
                // Info-ZIP Unicode path, valid only while its CRC matches the stored name.
                if (try? field.u8()) == 1, let nameCRC = try? field.u32le(),
                   nameCRC == UInt32(zlib.crc32(0, rawName.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(rawName.count))) {
                    // Version byte and CRC first, then the UTF-8 name.
                    unicodeName = String(decoding: UnsafeRawBufferPointer(rebasing: data[5...]), as: UTF8.self)
                }
            default:
                break
            }
        }

        let host = madeBy >> 8
        var name = unicodeName ?? decodeName(rawName, utf8: flags & 0x0800 != 0)
        if host == 0 || host == 11 || host == 14, name.contains("\\") {
            name = name.replacingOccurrences(of: "\\", with: "/")
        }
        let unixMode = host == 3 || host == 19 ? UInt32(external >> 16) & 0o170000 : 0
        let isDirectory = name.hasSuffix("/") || unixMode == 0o040000 || external & 0x10 != 0
        let path = ArchiveEntry.normalize(name)
        guard !path.isEmpty else { return nil }
        return ZipEntry(path: path, compressedSize: compressed, uncompressedSize: uncompressed,
                        modified: modified, isDirectory: isDirectory, isSymlink: unixMode == 0o120000,
                        isEncrypted: flags & 1 != 0, method: method, crc32: crc,
                        localHeaderOffset: localOffset)
    }

    /// Names are UTF-8 when the archive says so and CP437 otherwise, except
    /// that Archive Utility writes UTF-8 without setting the flag, so bytes
    /// that are valid UTF-8 are read as UTF-8.
    static func decodeName(_ raw: UnsafeRawBufferPointer, utf8: Bool) -> String {
        if utf8 || !raw.contains(where: { $0 >= 0x80 }) {
            return String(decoding: raw, as: UTF8.self)
        }
        if let text = String(bytes: raw, encoding: .utf8) { return text }
        var scalars = String.UnicodeScalarView()
        for byte in raw {
            scalars.append(byte < 0x80 ? Unicode.Scalar(byte) : cp437High[Int(byte) - 0x80])
        }
        return String(scalars)
    }

    private static let cp437High: [Unicode.Scalar] = Array((
        "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐"
        + "└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}"
    ).unicodeScalars)

    // MARK: - Member data

    private func read(_ entry: ZipEntry, limit: Int, wholeMember: Bool) throws -> Data {
        guard !entry.isEncrypted else { throw ArchiveError.unsupported("\(entry.path) is encrypted") }
        guard !entry.isDirectory else { return Data() }
        let (headerOffset, overflow) = entry.localHeaderOffset.addingReportingOverflow(shift)
        guard !overflow else { throw ArchiveError.corrupt("\(entry.path) has an impossible offset") }
        let header = try file.readExactly(at: headerOffset, count: 30, "local header of \(entry.path)")
        let (nameLength, extraLength) = try header.withUnsafeBytes { buffer -> (UInt64, UInt64) in
            var cursor = ByteCursor(buffer)
            guard try cursor.u32le() == 0x0403_4B50 else {
                throw ArchiveError.corrupt("Bad local header for \(entry.path)")
            }
            try cursor.skip(22)
            return (UInt64(try cursor.u16le()), UInt64(try cursor.u16le()))
        }
        let start = headerOffset + 30 + nameLength + extraLength
        guard start <= file.size, entry.compressedSize <= file.size - start else {
            throw ArchiveError.truncated("The archive ends inside \(entry.path)")
        }

        switch entry.method {
        case 0:
            let count = Int(min(entry.compressedSize, UInt64(limit)))
            return Data(try file.readExactly(at: start, count: count, "data of \(entry.path)"))
        case 8:
            return try inflateMember(from: start, length: entry.compressedSize, limit: limit,
                                     wholeMember: wholeMember, name: entry.path)
        default:
            throw ArchiveError.unsupported("\(entry.path) uses compression method \(entry.method)")
        }
    }

    private func inflateMember(from start: UInt64, length: UInt64, limit: Int,
                               wholeMember: Bool, name: String) throws -> Data {
        let inflater = try Inflater(.raw)
        let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 1)
        defer { chunk.deallocate() }
        var output = Data()
        var position = start
        let end = start + length
        var input: [UInt8] = []
        var inputIndex = 0
        while true {
            if inputIndex == input.count, position < end {
                input = try file.read(at: position, count: Int(min(256 * 1024, end - position)))
                position += UInt64(input.count)
                inputIndex = 0
            }
            let step = input.withUnsafeBytes { buffer in
                inflater.decode(UnsafeRawBufferPointer(rebasing: buffer[inputIndex...]), into: chunk)
            }
            if let failure = step.failure { throw failure }
            inputIndex += step.consumed
            if output.count + step.produced > limit {
                guard !wholeMember else { throw ArchiveError.tooLarge("\(name) inflates past \(limit) bytes") }
                output.append(contentsOf: chunk[0..<(limit - output.count)])
                return output
            }
            output.append(contentsOf: chunk[0..<step.produced])
            if step.ended || (!wholeMember && output.count == limit) { return output }
            if step.consumed == 0, step.produced == 0, inputIndex == input.count, position >= end {
                throw ArchiveError.truncated("The compressed data of \(name) ends early")
            }
        }
    }
}

/// Converts MS-DOS timestamps, which are local wall-clock time, to dates.
/// Calendar math per entry is slow at 50,000 entries, so this does the
/// arithmetic itself and only asks the time zone once per hour of the year.
struct DosDateConverter {
    private var offsets: [Int: Int] = [:]

    mutating func date(dosDate: UInt16, dosTime: UInt16) -> Date? {
        if dosDate == 0 && dosTime == 0 { return nil }
        let year = 1980 + Int(dosDate >> 9)
        let month = Int(dosDate >> 5 & 0x0F)
        let day = Int(dosDate & 0x1F)
        let hour = Int(dosTime >> 11)
        let minute = Int(dosTime >> 5 & 0x3F)
        let second = Int(dosTime & 0x1F) * 2
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else {
            return nil
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        let local = days * 86_400 + hour * 3_600 + minute * 60 + second
        let key = days * 24 + hour
        let offset: Int
        if let cached = offsets[key] {
            offset = cached
        } else {
            offset = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(local)))
            offsets[key] = offset
        }
        return Date(timeIntervalSince1970: TimeInterval(local - offset))
    }
}

/// Days from 1970-01-01 to a proleptic Gregorian date.
func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}
