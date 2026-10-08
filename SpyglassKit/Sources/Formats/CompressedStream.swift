import Foundation

public enum CompressionFormat: Sendable {
    case gzip, bzip2, xz

    /// The bytes every stream (gzip member) of this format starts with.
    var magic: [UInt8] {
        switch self {
        case .gzip: return [0x1F, 0x8B]
        case .bzip2: return Array("BZh".utf8)
        case .xz: return [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]
        }
    }

    func makeDecoder() throws -> StreamDecoder {
        switch self {
        case .gzip: return try Inflater(.gzip)
        case .bzip2: return try Bunzipper()
        case .xz: return try XZDecoder()
        }
    }
}

/// Decompresses a gzip, bzip2 or xz file a chunk at a time and hands each
/// chunk to a consumer, so nothing holds the whole decompressed stream.
/// Follows concatenated streams (`cat a.gz b.gz`, pbzip2's multi-stream
/// output, `xz` streams with padding between them).
struct DecompressingReader {
    enum Stop: Equatable {
        case endOfStream
        /// The consumer asked to stop.
        case consumer
        case byteLimit
        case timeLimit
        /// The file ends inside the compressed data.
        case truncated
        case corrupt(ArchiveError)
    }

    let file: FileBytes
    let format: CompressionFormat

    /// Runs until the stream ends, `consume` returns false, a limit stops
    /// it, or the data turns out damaged. `produced` counts the bytes
    /// handed to the consumer.
    func run(limits: ArchiveLimits,
             _ consume: (UnsafeRawBufferPointer) throws -> Bool) throws -> (stop: Stop, produced: UInt64) {
        let decoder = try format.makeDecoder()
        let deadline = monotonicSeconds() + limits.maxDuration
        let output = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 16)
        defer { output.deallocate() }
        var input: [UInt8] = []
        var inputIndex = 0
        var fileOffset: UInt64 = 0
        var produced: UInt64 = 0

        /// Moves unread input to the front and appends the next read.
        func refill() throws -> Bool {
            guard fileOffset < file.size else { return false }
            let more = try file.read(at: fileOffset, count: 256 * 1024)
            guard !more.isEmpty else { return false }
            fileOffset += UInt64(more.count)
            input = Array(input[inputIndex...]) + more
            inputIndex = 0
            return true
        }

        /// After one stream ends: does another start right here?
        func anotherStreamFollows() throws -> Bool {
            if format == .xz {
                // xz allows zero bytes ("stream padding") between streams.
                var padding = 0
                while padding < 1 << 20 {
                    if inputIndex == input.count, !(try refill()) { return false }
                    guard input[inputIndex] == 0 else { break }
                    inputIndex += 1
                    padding += 1
                }
            }
            let magic = format.magic
            if input.count - inputIndex < magic.count + 1 { _ = try refill() }
            return input[inputIndex...].starts(with: magic)
        }

        while true {
            if inputIndex == input.count, !(try refill()) {
                return (.truncated, produced)
            }
            let step = input.withUnsafeBytes { buffer in
                decoder.decode(UnsafeRawBufferPointer(rebasing: buffer[inputIndex...]), into: output)
            }
            inputIndex += step.consumed

            if step.produced > 0 {
                let room = limits.maxDecompressedBytes - min(produced, limits.maxDecompressedBytes)
                let allowed = Int(min(UInt64(step.produced), room))
                produced += UInt64(allowed)
                if allowed > 0, try !consume(UnsafeRawBufferPointer(rebasing: output[0..<allowed])) {
                    return (.consumer, produced)
                }
                if allowed < step.produced { return (.byteLimit, produced) }
            }
            if let failure = step.failure { return (.corrupt(failure), produced) }
            if step.ended {
                guard try anotherStreamFollows() else { return (.endOfStream, produced) }
                do { try decoder.reset() } catch let error as ArchiveError { return (.corrupt(error), produced) }
                continue
            }
            if produced >= limits.maxDecompressedBytes { return (.byteLimit, produced) }
            if step.consumed == 0, step.produced == 0, inputIndex < input.count {
                return (.corrupt(.corrupt("The compressed data is corrupt")), produced)
            }
            if monotonicSeconds() > deadline { return (.timeLimit, produced) }
        }
    }
}

/// Lists a `.gz` / `.bz2` / `.xz`: a compressed tarball lists its members;
/// any other compressed file shows as its one member with its decompressed
/// size.
public enum CompressedArchive {

    public static func list(_ url: URL, format: CompressionFormat,
                            limits: ArchiveLimits = .standard) throws -> ArchiveListing {
        let file = try FileBytes(url: url)
        let head = try file.read(at: 0, count: 64 * 1024)
        var gzip: GzipHeader?
        switch format {
        case .gzip:
            guard let header = GzipHeader(head) else { throw ArchiveError.unrecognized("Not a gzip file") }
            gzip = header
        case .bzip2:
            guard head.count >= 4, head.starts(with: Array("BZh".utf8)), (0x31...0x39).contains(head[3]) else {
                throw ArchiveError.unrecognized("Not a bzip2 file")
            }
        case .xz:
            guard head.starts(with: CompressionFormat.xz.magic) else { throw ArchiveError.unrecognized("Not an xz file") }
        }

        // xz records every block's uncompressed size in its index, so once
        // the data turns out not to be a tarball nothing more needs decoding.
        let indexedSize = format == .xz ? (try? XZIndex.uncompressedSize(of: file)) : nil

        // The first 512 decompressed bytes decide: tar header or not.
        var sniffed: [UInt8] = []
        var isTar: Bool?
        var parser = TarParser(maxEntries: limits.maxEntries)
        var tarFailure: ArchiveError?
        let reader = DecompressingReader(file: file, format: format)
        let (stop, produced) = try reader.run(limits: limits) { chunk in
            var rest = chunk
            if isTar == nil {
                let take = min(512 - sniffed.count, rest.count)
                sniffed.append(contentsOf: rest[0..<take])
                rest = UnsafeRawBufferPointer(rebasing: rest[take...])
                guard sniffed.count == 512 else { return true }
                isTar = TarParser.looksLikeHeader(sniffed)
                guard isTar == true else { return indexedSize == nil }
                do {
                    try sniffed.withUnsafeBytes { try parser.feed($0) }
                } catch let error as ArchiveError {
                    tarFailure = error
                    return false
                }
            }
            guard isTar == true else { return indexedSize == nil }
            do {
                try parser.feed(rest)
            } catch let error as ArchiveError {
                tarFailure = error
                return false
            }
            return !parser.isFinished
        }

        if isTar == true {
            if let tarFailure { return try parser.listing(failure: tarFailure) }
            switch stop {
            case .endOfStream, .consumer:
                return try parser.listingAtEndOfInput()
            case .byteLimit, .timeLimit:
                return parser.listing(incomplete: .workLimit(decompressedBytes: produced))
            case .truncated:
                return try parser.listing(failure: .truncated("The compressed data ends early"))
            case .corrupt(let error):
                return try parser.listing(failure: error)
            }
        }

        // A single compressed file.
        var size = produced
        var incomplete: ArchiveListing.Incomplete?
        switch stop {
        case .endOfStream:
            break
        case .consumer:
            // Only an xz file stops early, once its index gave the size.
            size = indexedSize ?? produced
        case .byteLimit, .timeLimit:
            incomplete = .workLimit(decompressedBytes: produced)
            // The gzip trailer records the last member's size mod 4 GiB:
            // exact for the usual single-member file, and the best figure
            // left once decompression stops early.
            if format == .gzip, let trailer = try? file.read(at: file.size - 4, count: 4), trailer.count == 4 {
                let recorded = UInt64(trailer[0]) | UInt64(trailer[1]) << 8
                    | UInt64(trailer[2]) << 16 | UInt64(trailer[3]) << 24
                size = max(size, recorded)
            }
        case .truncated:
            guard produced > 0 else { throw ArchiveError.truncated("The compressed data ends early") }
            incomplete = .damaged("The compressed data ends early")
        case .corrupt(let error):
            guard produced > 0 else { throw error }
            incomplete = .damaged(error.description)
        }
        let name = gzip?.name.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
            ?? memberName(forArchiveNamed: url.lastPathComponent)
        let entry = ArchiveEntry(path: name, kind: .file, size: size, modified: gzip?.modified)
        return ArchiveListing(entries: [entry], incomplete: incomplete, isSingleFile: true)
    }

    /// "dump.sql.gz" holds "dump.sql"; "src.tgz" holds "src.tar".
    static func memberName(forArchiveNamed filename: String) -> String {
        let lower = filename.lowercased()
        let suffixes = [(".tgz", ".tar"), (".tbz2", ".tar"), (".tbz", ".tar"), (".txz", ".tar"),
                        (".gz", ""), (".gzip", ""), (".bz2", ""), (".bz", ""), (".xz", "")]
        for (suffix, replacement) in suffixes where lower.hasSuffix(suffix) && lower.count > suffix.count {
            return String(filename.dropLast(suffix.count)) + replacement
        }
        return filename
    }
}

/// The fields of a gzip member header worth showing.
struct GzipHeader {
    var name: String?
    var modified: Date?

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 10, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        let mtime = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        modified = mtime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(mtime))
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { return }
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        if flags & 0x08 != 0, index < bytes.count,
           let end = bytes[index...].firstIndex(of: 0) {
            // The format says Latin-1; most writers today store UTF-8.
            let raw = Array(bytes[index..<end])
            name = String(bytes: raw, encoding: .utf8) ?? String(bytes: raw, encoding: .isoLatin1)
        }
    }
}

/// The uncompressed size an xz file records in its indexes, read from the
/// end backwards (padding, footer, index, blocks, header for each stream)
/// without decompressing anything.
enum XZIndex {
    static func uncompressedSize(of file: FileBytes, maxStreams: Int = 1_000) throws -> UInt64 {
        var end = file.size
        var total: UInt64 = 0
        for _ in 0..<maxStreams {
            // Stream padding: zero bytes in groups of four.
            var padding = 0
            while end >= 4, padding < 1 << 20, try file.readExactly(at: end - 4, count: 4, "xz padding") == [0, 0, 0, 0] {
                end -= 4
                padding += 4
            }
            if end == 0 { return total }
            guard end >= 24 else { throw ArchiveError.corrupt("The xz stream is too short") }

            let footer = try file.readExactly(at: end - 12, count: 12, "xz footer")
            guard footer[10] == 0x59, footer[11] == 0x5A else { throw ArchiveError.corrupt("The xz footer is missing") }
            let backward = UInt64(footer[4]) | UInt64(footer[5]) << 8 | UInt64(footer[6]) << 16 | UInt64(footer[7]) << 24
            let indexSize = (backward + 1) * 4
            guard indexSize <= 64 << 20, indexSize + 24 <= end else { throw ArchiveError.corrupt("The xz index size is impossible") }
            let indexStart = end - 12 - indexSize
            let index = try file.readExactly(at: indexStart, count: Int(indexSize), "xz index")

            // Each record: the block's unpadded and uncompressed sizes.
            let blocks = try index.withUnsafeBytes { buffer -> UInt64 in
                var cursor = ByteCursor(buffer)
                guard try cursor.u8() == 0 else { throw ArchiveError.corrupt("The xz index is damaged") }
                var remaining = try varint(&cursor)
                var blocks: UInt64 = 0
                while remaining > 0 {
                    let unpadded = try varint(&cursor)
                    let uncompressed = try varint(&cursor)
                    let (sum, overflow) = total.addingReportingOverflow(uncompressed)
                    guard !overflow, unpadded <= indexStart else { throw ArchiveError.corrupt("The xz index is damaged") }
                    total = sum
                    blocks += (unpadded + 3) & ~3
                    guard blocks <= indexStart else { throw ArchiveError.corrupt("The xz index doesn't match the file") }
                    remaining -= 1
                }
                return blocks
            }
            guard blocks + 12 <= indexStart else { throw ArchiveError.corrupt("The xz index doesn't match the file") }
            let start = indexStart - blocks - 12
            guard try file.readExactly(at: start, count: 6, "xz header") == CompressionFormat.xz.magic else {
                throw ArchiveError.corrupt("The xz index doesn't match the file")
            }
            end = start
            if end == 0 { return total }
        }
        throw ArchiveError.tooLarge("The xz file has too many streams")
    }

    /// An xz variable-length integer: 7 bits per byte, low bits first.
    private static func varint(_ cursor: inout ByteCursor) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 63, by: 7) {
            let byte = try cursor.u8()
            value |= UInt64(byte & 0x7F) << UInt64(shift)
            if byte & 0x80 == 0 { return value }
        }
        throw ArchiveError.corrupt("The xz index is damaged")
    }
}
