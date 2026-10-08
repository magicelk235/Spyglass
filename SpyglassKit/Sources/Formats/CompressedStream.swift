import Foundation

public enum CompressionFormat: Sendable {
    case gzip, bzip2
}

/// Decompresses a gzip or bzip2 file a chunk at a time and hands each chunk
/// to a consumer, so nothing holds the whole decompressed stream. Follows
/// concatenated members (`cat a.gz b.gz`, pbzip2's multi-stream output).
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
        let decoder: StreamDecoder = format == .gzip ? try Inflater(.gzip) : try Bunzipper()
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
            let magic: [UInt8] = format == .gzip ? [0x1F, 0x8B] : Array("BZh".utf8)
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

/// Lists a `.gz` / `.bz2`: a compressed tarball lists its members; any
/// other compressed file shows as its one member with its decompressed size.
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
        }

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
                guard isTar == true else { return true }
                do {
                    try sniffed.withUnsafeBytes { try parser.feed($0) }
                } catch let error as ArchiveError {
                    tarFailure = error
                    return false
                }
            }
            guard isTar == true else { return true }
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
        case .endOfStream, .consumer:
            break
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
        let suffixes = [(".tgz", ".tar"), (".tbz2", ".tar"), (".tbz", ".tar"),
                        (".gz", ""), (".gzip", ""), (".bz2", ""), (".bz", "")]
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
