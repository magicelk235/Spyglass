import Compression
import Foundation
import zlib
import CBzip2

/// Random-access reads from a file. Reads past the end come back short
/// instead of failing, so callers decide whether that means "truncated".
final class FileBytes {
    private let handle: FileHandle
    let size: UInt64

    init(url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ArchiveError.unrecognized("Can't open \(url.lastPathComponent)")
        }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_size >= 0 else {
            throw ArchiveError.unrecognized("Can't read \(url.lastPathComponent)")
        }
        self.handle = handle
        self.size = UInt64(info.st_size)
    }

    deinit { try? handle.close() }

    /// Up to `count` bytes starting at `offset`; fewer at the end of the file.
    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard count > 0, offset < size else { return [] }
        let wanted = Int(min(UInt64(count), size - offset))
        let fd = handle.fileDescriptor
        return try [UInt8](unsafeUninitializedCapacity: wanted) { buffer, initialized in
            var done = 0
            while done < wanted {
                let got = pread(fd, buffer.baseAddress! + done, wanted - done, off_t(offset) + off_t(done))
                if got < 0 {
                    if errno == EINTR { continue }
                    initialized = done
                    throw ArchiveError.truncated("The file couldn't be read")
                }
                if got == 0 { break }
                done += got
            }
            initialized = done
        }
    }

    /// Exactly `count` bytes, or `.truncated` naming `what` was cut off.
    func readExactly(at offset: UInt64, count: Int, _ what: String) throws -> [UInt8] {
        let bytes = try read(at: offset, count: count)
        guard bytes.count == count else { throw ArchiveError.truncated("The file ends inside the \(what)") }
        return bytes
    }
}

/// Bounds-checked reads over a byte buffer. Every read past the end throws,
/// so a malformed length field can never walk off the buffer.
struct ByteCursor {
    let base: UnsafeRawBufferPointer
    var offset: Int

    init(_ base: UnsafeRawBufferPointer, offset: Int = 0) {
        self.base = base
        self.offset = offset
    }

    var remaining: Int { base.count - offset }

    private func need(_ count: Int) throws {
        guard count >= 0, offset >= 0, count <= base.count - offset else {
            throw ArchiveError.truncated("A record runs past the end of its data")
        }
    }

    mutating func skip(_ count: Int) throws {
        try need(count)
        offset += count
    }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return base[offset]
    }

    mutating func u16le() throws -> UInt16 {
        try need(2)
        defer { offset += 2 }
        return UInt16(base[offset]) | UInt16(base[offset + 1]) << 8
    }

    mutating func u32le() throws -> UInt32 {
        try need(4)
        defer { offset += 4 }
        return UInt32(base[offset]) | UInt32(base[offset + 1]) << 8
            | UInt32(base[offset + 2]) << 16 | UInt32(base[offset + 3]) << 24
    }

    mutating func u64le() throws -> UInt64 {
        let low = UInt64(try u32le())
        return UInt64(try u32le()) << 32 | low
    }

    mutating func u16be() throws -> UInt16 {
        try need(2)
        defer { offset += 2 }
        return UInt16(base[offset]) << 8 | UInt16(base[offset + 1])
    }

    mutating func u32be() throws -> UInt32 {
        try need(4)
        defer { offset += 4 }
        return UInt32(base[offset]) << 24 | UInt32(base[offset + 1]) << 16
            | UInt32(base[offset + 2]) << 8 | UInt32(base[offset + 3])
    }

    mutating func u64be() throws -> UInt64 {
        let high = UInt64(try u32be())
        return high << 32 | UInt64(try u32be())
    }

    mutating func bytes(_ count: Int) throws -> UnsafeRawBufferPointer {
        try need(count)
        defer { offset += count }
        return UnsafeRawBufferPointer(rebasing: base[offset..<(offset + count)])
    }
}

/// One step of a streaming decompressor: how much input it took, how much
/// output it wrote, whether the compressed stream (one gzip member, bzip2
/// stream or xz stream) ended, and whether it failed. The output written
/// before a failure is valid as far as it goes: a bad checksum is only
/// found after the data it covers.
struct DecodeStep {
    var consumed: Int
    var produced: Int
    var ended = false
    var failure: ArchiveError?
}

protocol StreamDecoder: AnyObject {
    func decode(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) -> DecodeStep
    /// Starts over for the next concatenated stream.
    func reset() throws
}

/// Streaming zlib inflate. The `z_stream` lives at a fixed heap address
/// because zlib keeps a pointer back to it between calls.
final class Inflater: StreamDecoder {
    enum Wrapper { case raw, zlib, gzip }

    private let stream: UnsafeMutablePointer<z_stream>

    init(_ wrapper: Wrapper) throws {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        let windowBits: Int32
        switch wrapper {
        case .raw: windowBits = -MAX_WBITS
        case .zlib: windowBits = MAX_WBITS
        case .gzip: windowBits = 16 + MAX_WBITS
        }
        guard inflateInit2_(stream, windowBits, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            stream.deinitialize(count: 1)
            stream.deallocate()
            throw ArchiveError.unsupported("zlib couldn't start")
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    func decode(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) -> DecodeStep {
        stream.pointee.next_in = input.baseAddress.map {
            UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: Bytef.self))
        }
        stream.pointee.avail_in = uInt(input.count)
        stream.pointee.next_out = output.baseAddress?.assumingMemoryBound(to: Bytef.self)
        stream.pointee.avail_out = uInt(output.count)
        let status = inflate(stream, Z_NO_FLUSH)
        var step = DecodeStep(consumed: input.count - Int(stream.pointee.avail_in),
                              produced: output.count - Int(stream.pointee.avail_out),
                              ended: status == Z_STREAM_END)
        switch status {
        case Z_OK, Z_BUF_ERROR, Z_STREAM_END:
            break
        case Z_MEM_ERROR:
            step.failure = .tooLarge("zlib ran out of memory")
        default:
            step.failure = .corrupt("The compressed data is corrupt")
        }
        return step
    }

    func reset() throws {
        guard inflateReset(stream) == Z_OK else { throw ArchiveError.corrupt("zlib couldn't restart") }
    }
}

/// Streaming bzip2 decompression.
final class Bunzipper: StreamDecoder {
    private let stream: UnsafeMutablePointer<bz_stream>
    private var active = false

    init() throws {
        stream = .allocate(capacity: 1)
        stream.initialize(to: bz_stream())
        do {
            try start()
        } catch {
            stream.deinitialize(count: 1)
            stream.deallocate()
            throw error
        }
    }

    deinit {
        if active { BZ2_bzDecompressEnd(stream) }
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    private func start() throws {
        stream.pointee = bz_stream()
        guard BZ2_bzDecompressInit(stream, 0, 0) == BZ_OK else {
            throw ArchiveError.unsupported("bzip2 couldn't start")
        }
        active = true
    }

    func decode(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) -> DecodeStep {
        stream.pointee.next_in = input.baseAddress.map {
            UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: CChar.self))
        }
        stream.pointee.avail_in = UInt32(input.count)
        stream.pointee.next_out = output.baseAddress?.assumingMemoryBound(to: CChar.self)
        stream.pointee.avail_out = UInt32(output.count)
        let status = BZ2_bzDecompress(stream)
        var step = DecodeStep(consumed: input.count - Int(stream.pointee.avail_in),
                              produced: output.count - Int(stream.pointee.avail_out),
                              ended: status == BZ_STREAM_END)
        switch status {
        case BZ_OK, BZ_STREAM_END:
            break
        case BZ_MEM_ERROR:
            step.failure = .tooLarge("bzip2 ran out of memory")
        default:
            step.failure = .corrupt("The compressed data is corrupt")
        }
        return step
    }

    func reset() throws {
        if active { BZ2_bzDecompressEnd(stream) }
        active = false
        try start()
    }
}

/// Streaming xz decompression through the Compression framework, whose
/// LZMA decoder reads the xz container (one stream per decoder).
final class XZDecoder: StreamDecoder {
    private let stream: UnsafeMutablePointer<compression_stream>
    private var active = false
    /// Stands in for an empty buffer's missing base address.
    private static let empty = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)

    init() throws {
        stream = .allocate(capacity: 1)
        do {
            try start()
        } catch {
            stream.deallocate()
            throw error
        }
    }

    deinit {
        if active { compression_stream_destroy(stream) }
        stream.deallocate()
    }

    private func start() throws {
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            throw ArchiveError.unsupported("xz couldn't start")
        }
        active = true
    }

    func decode(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) -> DecodeStep {
        stream.pointee.src_ptr = input.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer(Self.empty)
        stream.pointee.src_size = input.count
        stream.pointee.dst_ptr = output.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? Self.empty
        stream.pointee.dst_size = output.count
        let status = compression_stream_process(stream, 0)
        var step = DecodeStep(consumed: input.count - stream.pointee.src_size,
                              produced: output.count - stream.pointee.dst_size,
                              ended: status == COMPRESSION_STATUS_END)
        if status == COMPRESSION_STATUS_ERROR {
            step.failure = .corrupt("The compressed data is corrupt")
        }
        return step
    }

    func reset() throws {
        if active { compression_stream_destroy(stream) }
        active = false
        try start()
    }
}

/// Decodes a whole in-memory buffer, refusing to produce more than `limit`
/// bytes. For small members: a xar table of contents, a plist.
func decodeAll(_ data: [UInt8], with decoder: StreamDecoder, limit: Int) throws -> [UInt8] {
    var output: [UInt8] = []
    let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 1)
    defer { chunk.deallocate() }
    var position = 0
    while true {
        let step = data.withUnsafeBytes { input in
            decoder.decode(UnsafeRawBufferPointer(rebasing: input[position...]), into: chunk)
        }
        if let failure = step.failure { throw failure }
        position += step.consumed
        guard output.count + step.produced <= limit else {
            throw ArchiveError.tooLarge("The data inflates past \(limit) bytes")
        }
        output.append(contentsOf: chunk[0..<step.produced])
        if step.ended { return output }
        if step.consumed == 0 && step.produced == 0 {
            throw ArchiveError.truncated("The compressed data ends early")
        }
    }
}

/// Seconds since boot; immune to clock changes, for time budgets.
func monotonicSeconds() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}
