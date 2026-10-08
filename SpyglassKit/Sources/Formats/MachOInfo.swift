import Foundation

/// What a Mach-O file's headers and load commands say about it: one
/// `MachOSlice` per architecture. Only the header and load commands are
/// read, so a binary of any size costs a few kilobytes.
public struct MachOInfo: Equatable, Sendable {
    /// Every architecture in the file; one entry for a thin binary.
    public var slices: [MachOSlice]
    /// The file has a universal (fat) header, even if it lists one slice.
    public var isUniversal: Bool

    public static func read(at url: URL) throws -> MachOInfo {
        let file = try FileBytes(url: url)
        let head = try file.read(at: 0, count: FatHeader.maxLength)
        if let fat = try FatHeader(head, fileSize: file.size) {
            return try read(file, fat: fat)
        }
        return MachOInfo(slices: [try MachOSlice.read(file, offset: 0, size: file.size)], isUniversal: false)
    }

    static func read(_ file: FileBytes, fat: FatHeader) throws -> MachOInfo {
        let slices = try fat.slices.map { try MachOSlice.read(file, offset: $0.offset, size: $0.size) }
        return MachOInfo(slices: slices, isUniversal: true)
    }

    /// True for the four Mach-O magics, either byte order.
    static func isMachO(_ head: [UInt8]) -> Bool {
        guard head.count >= 4 else { return false }
        let magic = UInt32(head[0]) << 24 | UInt32(head[1]) << 16 | UInt32(head[2]) << 8 | UInt32(head[3])
        return MachOSlice.layout(forMagic: magic) != nil
    }
}

/// One architecture of a Mach-O file.
public struct MachOSlice: Equatable, Sendable {
    public enum FileType: Equatable, Sendable {
        case object, executable, dylib, bundle, dylinker, dsym, kernelExtension, fileset, core, preload
        case other(UInt32)

        init(_ raw: UInt32) {
            switch raw {
            case 0x1: self = .object
            case 0x2: self = .executable
            case 0x4: self = .core
            case 0x5: self = .preload
            case 0x6, 0x9: self = .dylib
            case 0x7: self = .dylinker
            case 0x8: self = .bundle
            case 0xA: self = .dsym
            case 0xB: self = .kernelExtension
            case 0xC: self = .fileset
            default: self = .other(raw)
            }
        }

        public var displayName: String {
            switch self {
            case .object: return "Object file"
            case .executable: return "Executable"
            case .dylib: return "Dynamic library"
            case .bundle: return "Bundle"
            case .dylinker: return "Dynamic linker"
            case .dsym: return "Debug symbols"
            case .kernelExtension: return "Kernel extension"
            case .fileset: return "Kernel collection"
            case .core: return "Core dump"
            case .preload: return "Preloaded executable"
            case .other(let raw): return "Mach-O file type \(raw)"
            }
        }
    }

    /// A platform the slice was built for (`LC_BUILD_VERSION`, or the older
    /// `LC_VERSION_MIN_*` commands).
    public struct BuildVersion: Equatable, Sendable {
        public var platform: String
        public var minimumOS: String
        /// nil when the SDK isn't recorded.
        public var sdk: String?
    }

    public struct Library: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case normal, weak, reexport, lazy, upward
        }

        public var path: String
        public var kind: Kind
        public var currentVersion: String
        public var compatibilityVersion: String
    }

    public struct Section: Equatable, Sendable {
        public var segment: String
        public var name: String
        public var size: UInt64
    }

    public struct Segment: Equatable, Sendable {
        /// Empty in object files, whose one segment holds every section.
        public var name: String
        public var vmSize: UInt64
        public var fileSize: UInt64
        public var sections: [Section]
    }

    /// "arm64", "x86_64", "arm64e"...
    public var architecture: String
    public var is64Bit: Bool
    public var isBigEndian: Bool
    public var fileType: FileType
    /// The header's `MH_*` flags.
    public var flags: UInt32
    public var uuid: UUID?
    public var buildVersions: [BuildVersion]
    /// A dylib's own install name and versions (`LC_ID_DYLIB`).
    public var identity: Library?
    public var libraries: [Library]
    public var rpaths: [String]
    /// Has `LC_MAIN`, the entry point of a modern executable.
    public var hasMain: Bool
    /// nil without `LC_ENCRYPTION_INFO`; true when the slice is still
    /// encrypted (an App Store binary).
    public var isEncrypted: Bool?
    public var hasCodeSignature: Bool
    public var segments: [Segment]
    /// Where the slice sits in the file, and its length.
    public var offset: UInt64
    public var size: UInt64

    /// The header flags worth naming, in a fixed order.
    public var notableFlags: [String] {
        let names: [(UInt32, String)] = [
            (0x0020_0000, "PIE"),
            (0x0000_0080, "Two-level namespace"),
            (0x0200_0000, "App-extension safe"),
            (0x0100_0000, "No heap execution"),
            (0x0002_0000, "Allows stack execution"),
        ]
        return names.compactMap { flags & $0.0 != 0 ? $0.1 : nil }
    }

    /// Load commands larger than this are refused; real binaries use a few
    /// hundred kilobytes at most.
    static let maxLoadCommandBytes = 4 << 20

    /// (64-bit, big-endian) for a Mach-O magic read big-endian.
    static func layout(forMagic magic: UInt32) -> (is64Bit: Bool, isBigEndian: Bool)? {
        switch magic {
        case 0xCFFA_EDFE: return (true, false)   // MH_MAGIC_64 stored little-endian
        case 0xCEFA_EDFE: return (false, false)  // MH_MAGIC
        case 0xFEED_FACF: return (true, true)    // big-endian (PowerPC) files
        case 0xFEED_FACE: return (false, true)
        default: return nil
        }
    }

    /// Reads the slice at `offset`, which may run `size` bytes.
    static func read(_ file: FileBytes, offset: UInt64, size: UInt64) throws -> MachOSlice {
        let header = try file.read(at: offset, count: 32)
        guard header.count >= 4,
              let layout = layout(forMagic: UInt32(header[0]) << 24 | UInt32(header[1]) << 16
                                  | UInt32(header[2]) << 8 | UInt32(header[3])) else {
            throw ArchiveError.unrecognized("Not a Mach-O file")
        }
        let headerSize = layout.is64Bit ? 32 : 28
        guard header.count >= headerSize, size >= UInt64(headerSize) else {
            throw ArchiveError.truncated("The file ends inside the Mach-O header")
        }
        let big = layout.isBigEndian
        let (cpuType, cpuSubtype, fileType, commandCount, commandBytes, flags) = try header.withUnsafeBytes { buffer in
            var cursor = ByteCursor(buffer, offset: 4)
            return (try cursor.u32(big), try cursor.u32(big), try cursor.u32(big),
                    try cursor.u32(big), try cursor.u32(big), try cursor.u32(big))
        }
        guard UInt64(commandBytes) <= size - UInt64(headerSize) else {
            throw ArchiveError.truncated("The file ends inside the load commands")
        }
        guard commandBytes <= maxLoadCommandBytes else {
            throw ArchiveError.tooLarge("The load commands are too large to read")
        }
        guard UInt64(commandCount) * 8 <= UInt64(commandBytes) else {
            throw ArchiveError.corrupt("The header counts more load commands than fit")
        }

        var slice = MachOSlice(
            architecture: MachOHeader.name(type: cpuType, subtype: cpuSubtype),
            is64Bit: layout.is64Bit, isBigEndian: big, fileType: FileType(fileType), flags: flags,
            uuid: nil, buildVersions: [], identity: nil, libraries: [], rpaths: [], hasMain: false,
            isEncrypted: nil, hasCodeSignature: false, segments: [], offset: offset, size: size)
        let commands = try file.readExactly(at: offset + UInt64(headerSize), count: Int(commandBytes), "load commands")
        try commands.withUnsafeBytes { buffer in
            var start = 0
            for _ in 0..<commandCount {
                var cursor = ByteCursor(buffer, offset: start)
                let command = try cursor.u32(big)
                let length = Int(try cursor.u32(big))
                guard length >= 8, length <= buffer.count - start else {
                    throw ArchiveError.corrupt("A load command has an impossible size")
                }
                let body = UnsafeRawBufferPointer(rebasing: buffer[start..<(start + length)])
                try slice.apply(command: command, body: body)
                start += length
            }
        }
        return slice
    }

    /// Records what one load command says. `body` is the whole command,
    /// starting with its `cmd` and `cmdsize` fields.
    private mutating func apply(command: UInt32, body: UnsafeRawBufferPointer) throws {
        let big = isBigEndian
        var cursor = ByteCursor(body, offset: 8)
        switch command {
        case 0x1, 0x19:                                         // LC_SEGMENT, LC_SEGMENT_64
            let wide = command == 0x19
            let name = Self.fixedString(try cursor.bytes(16))
            try cursor.skip(wide ? 8 : 4)                       // vmaddr
            let vmSize = wide ? try cursor.u64(big) : UInt64(try cursor.u32(big))
            try cursor.skip(wide ? 8 : 4)                       // fileoff
            let fileSize = wide ? try cursor.u64(big) : UInt64(try cursor.u32(big))
            try cursor.skip(8)                                  // maxprot, initprot
            let sectionCount = try cursor.u32(big)
            try cursor.skip(4)                                  // flags
            var sections: [Section] = []
            let sectionLength = wide ? 80 : 68
            guard UInt64(sectionCount) * UInt64(sectionLength) <= UInt64(cursor.remaining) else {
                throw ArchiveError.corrupt("Segment \(name) lists more sections than fit")
            }
            for _ in 0..<sectionCount {
                let section = cursor.offset
                let sectionName = Self.fixedString(try cursor.bytes(16))
                let segmentName = Self.fixedString(try cursor.bytes(16))
                try cursor.skip(wide ? 8 : 4)                   // addr
                let size = wide ? try cursor.u64(big) : UInt64(try cursor.u32(big))
                sections.append(Section(segment: segmentName, name: sectionName, size: size))
                cursor.offset = section + sectionLength
            }
            segments.append(Segment(name: name, vmSize: vmSize, fileSize: fileSize, sections: sections))

        case 0x1B:                                              // LC_UUID
            let bytes = try cursor.bytes(16)
            uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))

        case 0xD:                                               // LC_ID_DYLIB
            identity = try Self.library(body, cursor: &cursor, kind: .normal, bigEndian: big)

        case 0xC, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023:
            let kind: Library.Kind
            switch command {
            case 0x8000_0018: kind = .weak                      // LC_LOAD_WEAK_DYLIB
            case 0x8000_001F: kind = .reexport                  // LC_REEXPORT_DYLIB
            case 0x20: kind = .lazy                             // LC_LAZY_LOAD_DYLIB
            case 0x8000_0023: kind = .upward                    // LC_LOAD_UPWARD_DYLIB
            default: kind = .normal                             // LC_LOAD_DYLIB
            }
            libraries.append(try Self.library(body, cursor: &cursor, kind: kind, bigEndian: big))

        case 0x8000_001C:                                       // LC_RPATH
            rpaths.append(try Self.string(in: body, at: try cursor.u32(big)))

        case 0x8000_0028:                                       // LC_MAIN
            hasMain = true

        case 0x21, 0x2C:                                        // LC_ENCRYPTION_INFO(_64)
            try cursor.skip(8)                                  // cryptoff, cryptsize
            let id = try cursor.u32(big)
            isEncrypted = (isEncrypted ?? false) || id != 0

        case 0x1D:                                              // LC_CODE_SIGNATURE
            hasCodeSignature = true

        case 0x32:                                              // LC_BUILD_VERSION
            let platform = try cursor.u32(big)
            let minimum = try cursor.u32(big)
            let sdk = try cursor.u32(big)
            buildVersions.append(BuildVersion(platform: Self.platformName(platform),
                                              minimumOS: Self.osVersion(minimum),
                                              sdk: sdk == 0 ? nil : Self.osVersion(sdk)))

        case 0x24, 0x25, 0x2F, 0x30:                            // LC_VERSION_MIN_*
            let platform: String
            switch command {
            case 0x24: platform = "macOS"
            case 0x25: platform = "iOS"
            case 0x2F: platform = "tvOS"
            default: platform = "watchOS"
            }
            let minimum = try cursor.u32(big)
            let sdk = try cursor.u32(big)
            buildVersions.append(BuildVersion(platform: platform, minimumOS: Self.osVersion(minimum),
                                              sdk: sdk == 0 ? nil : Self.osVersion(sdk)))

        default:
            break
        }
    }

    /// A `dylib_command`: name offset, timestamp, current and
    /// compatibility versions.
    private static func library(_ body: UnsafeRawBufferPointer, cursor: inout ByteCursor,
                                kind: Library.Kind, bigEndian big: Bool) throws -> Library {
        let nameOffset = try cursor.u32(big)
        try cursor.skip(4)                                      // timestamp
        let current = try cursor.u32(big)
        let compatibility = try cursor.u32(big)
        return Library(path: try string(in: body, at: nameOffset), kind: kind,
                       currentVersion: dylibVersion(current), compatibilityVersion: dylibVersion(compatibility))
    }

    /// An `lc_str`: a NUL-terminated string at `offset` within the command.
    private static func string(in body: UnsafeRawBufferPointer, at offset: UInt32) throws -> String {
        guard offset >= 8, Int(offset) < body.count else {
            throw ArchiveError.corrupt("A load command's string lies outside it")
        }
        let tail = UnsafeRawBufferPointer(rebasing: body[Int(offset)...])
        let end = tail.firstIndex(of: 0) ?? tail.count
        return String(decoding: UnsafeRawBufferPointer(rebasing: tail[0..<end]), as: UTF8.self)
    }

    /// A 16-byte name field, NUL-padded unless it's exactly 16 long.
    private static func fixedString(_ bytes: UnsafeRawBufferPointer) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[0..<end]), as: UTF8.self)
    }

    /// Dylib versions pack X.Y.Z as 16.8.8 bits and always show all three.
    static func dylibVersion(_ packed: UInt32) -> String {
        "\(packed >> 16).\(packed >> 8 & 0xFF).\(packed & 0xFF)"
    }

    /// OS versions use the same packing; "14.0" rather than "14.0.0".
    static func osVersion(_ packed: UInt32) -> String {
        let patch = packed & 0xFF
        return "\(packed >> 16).\(packed >> 8 & 0xFF)" + (patch == 0 ? "" : ".\(patch)")
    }

    static func platformName(_ platform: UInt32) -> String {
        switch platform {
        case 1: return "macOS"
        case 2: return "iOS"
        case 3: return "tvOS"
        case 4: return "watchOS"
        case 5: return "bridgeOS"
        case 6: return "Mac Catalyst"
        case 7: return "iOS Simulator"
        case 8: return "tvOS Simulator"
        case 9: return "watchOS Simulator"
        case 10: return "DriverKit"
        case 11: return "visionOS"
        case 12: return "visionOS Simulator"
        default: return "Platform \(platform)"
        }
    }
}

/// A universal file's table of slices (`fat_header` plus `fat_arch` or
/// `fat_arch_64` records, all big-endian).
struct FatHeader: Equatable {
    struct Slice: Equatable {
        var cpuType: UInt32
        var cpuSubtype: UInt32
        var offset: UInt64
        var size: UInt64

        var architecture: String { MachOHeader.name(type: cpuType, subtype: cpuSubtype) }
    }

    /// Java class files share the 0xCAFEBABE magic, with their major
    /// version (45 or more) where the slice count goes.
    static let maxSlices = 44
    /// Bytes that hold the largest table this reader accepts.
    static let maxLength = 8 + maxSlices * 32

    var slices: [Slice]

    /// nil when `head` doesn't start with a fat header. Throws when it
    /// does but the table is cut short or, given the file's size, points
    /// outside the file.
    init?(_ head: [UInt8], fileSize: UInt64?) throws {
        guard head.count >= 8 else { return nil }
        let parsed = try head.withUnsafeBytes { buffer -> [Slice]? in
            var cursor = ByteCursor(buffer)
            let magic = try cursor.u32be()
            guard magic == 0xCAFE_BABE || magic == 0xCAFE_BABF else { return nil }
            let wide = magic == 0xCAFE_BABF
            let count = try cursor.u32be()
            guard (1...UInt32(Self.maxSlices)).contains(count) else { return nil }
            var slices: [Slice] = []
            for _ in 0..<count {
                do {
                    let type = try cursor.u32be()
                    let subtype = try cursor.u32be()
                    let offset = wide ? try cursor.u64be() : UInt64(try cursor.u32be())
                    let size = wide ? try cursor.u64be() : UInt64(try cursor.u32be())
                    try cursor.skip(wide ? 8 : 4)               // align (+ reserved)
                    slices.append(Slice(cpuType: type, cpuSubtype: subtype, offset: offset, size: size))
                } catch {
                    throw ArchiveError.truncated("The file ends inside the universal header")
                }
            }
            return slices
        }
        guard let parsed else { return nil }
        if let fileSize {
            for slice in parsed {
                let (end, overflow) = slice.offset.addingReportingOverflow(slice.size)
                guard !overflow, end <= fileSize else {
                    throw ArchiveError.truncated("The \(slice.architecture) slice runs past the end of the file")
                }
            }
        }
        slices = parsed
    }
}

extension ByteCursor {
    mutating func u32(_ bigEndian: Bool) throws -> UInt32 {
        bigEndian ? try u32be() : try u32le()
    }

    mutating func u64(_ bigEndian: Bool) throws -> UInt64 {
        bigEndian ? try u64be() : try u64le()
    }

    mutating func u16(_ bigEndian: Bool) throws -> UInt16 {
        bigEndian ? try u16be() : try u16le()
    }
}
