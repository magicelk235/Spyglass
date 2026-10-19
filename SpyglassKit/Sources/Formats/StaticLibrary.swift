import Foundation

/// The members of a static library: an `ar` archive (BSD or GNU flavor),
/// or a universal file holding one archive per architecture. Only member
/// headers and each member's first bytes are read.
public struct StaticLibrary: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public var name: String
        public var size: UInt64
        public var modified: Date?
        /// The CPU an object member was built for; nil for anything else.
        public var architecture: String?
    }

    /// Members in archive order; a universal library lists each slice's
    /// members in turn.
    public var members: [Member]
    /// A universal library's slices, else the members' architectures in
    /// the order they first appear.
    public var architectures: [String]
    public var isUniversal: Bool
    /// Some archive carries a ranlib / GNU symbol table.
    public var hasSymbolIndex: Bool
    /// Listing stopped at the member limit.
    public var hitMemberLimit: Bool

    public static let defaultMemberLimit = 5_000

    static let magic = Array("!<arch>\n".utf8)

    static func isArchive(_ head: [UInt8]) -> Bool {
        head.starts(with: magic)
    }

    public static func read(at url: URL, memberLimit: Int = defaultMemberLimit) throws -> StaticLibrary {
        let file = try FileBytes(url: url)
        let head = try file.read(at: 0, count: FatHeader.maxLength)
        if let fat = try FatHeader(head, fileSize: file.size) {
            return try read(file, fat: fat, memberLimit: memberLimit)
        }
        var library = StaticLibrary(members: [], architectures: [], isUniversal: false,
                                    hasSymbolIndex: false, hitMemberLimit: false)
        try library.list(file, offset: 0, size: file.size, limit: memberLimit)
        for case let architecture? in library.members.map(\.architecture)
        where !library.architectures.contains(architecture) {
            library.architectures.append(architecture)
        }
        return library
    }

    static func read(_ file: FileBytes, fat: FatHeader, memberLimit: Int = defaultMemberLimit) throws -> StaticLibrary {
        var library = StaticLibrary(members: [], architectures: fat.slices.map(\.architecture), isUniversal: true,
                                    hasSymbolIndex: false, hitMemberLimit: false)
        for slice in fat.slices where !library.hitMemberLimit {
            try library.list(file, offset: slice.offset, size: slice.size, limit: memberLimit)
        }
        return library
    }

    /// Appends the members of the archive at `offset`.
    private mutating func list(_ file: FileBytes, offset: UInt64, size: UInt64, limit: Int) throws {
        guard size >= 8, try file.read(at: offset, count: 8) == Self.magic else {
            throw ArchiveError.unrecognized("Not a static library")
        }
        let end = offset + size
        var position = offset + 8
        var longNames: [UInt8] = []
        while position < end {
            // Some archivers pad the last member with a newline.
            if end - position < 60 {
                guard try file.read(at: position, count: Int(end - position)).allSatisfy({ $0 == 0x0A }) else {
                    throw ArchiveError.truncated("The archive ends inside a member header")
                }
                return
            }
            let header = try file.readExactly(at: position, count: 60, "member header")
            guard header[58] == 0x60, header[59] == 0x0A else {
                throw ArchiveError.corrupt("A member header is damaged")
            }
            let rawName = Self.text(header[0..<16])
            guard let declared = Self.decimal(header[48..<58]) else {
                throw ArchiveError.corrupt("A member header has a bad size")
            }
            var dataStart = position + 60
            var dataSize = declared
            guard dataSize <= end - dataStart else {
                throw ArchiveError.truncated("The archive ends inside \(rawName)")
            }
            position = dataStart + dataSize + (dataSize & 1)

            var name = rawName
            if rawName.hasPrefix("#1/") {
                // BSD: the name is the first n bytes of the member's data.
                guard let length = Self.decimal(Array(rawName.utf8.dropFirst(3))[...]),
                      length <= dataSize, length <= 4096 else {
                    throw ArchiveError.corrupt("A member's long name is damaged")
                }
                let bytes = try file.readExactly(at: dataStart, count: Int(length), "member name")
                name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                dataStart += length
                dataSize -= length
            } else if rawName == "//" {
                // GNU: the table that "/123" names point into.
                guard dataSize <= 16 << 20 else { throw ArchiveError.tooLarge("The long-name table is too large") }
                longNames = try file.readExactly(at: dataStart, count: Int(dataSize), "long-name table")
                continue
            } else if rawName == "/" || rawName == "/SYM64/" {
                hasSymbolIndex = true
                continue
            } else if rawName.hasPrefix("/"), let index = Self.decimal(Array(rawName.utf8.dropFirst())[...]) {
                guard index < UInt64(longNames.count) else {
                    throw ArchiveError.corrupt("A member's long name points outside the name table")
                }
                let tail = longNames[Int(index)...]
                let stop = tail.firstIndex(of: 0x0A) ?? tail.endIndex
                var bytes = Array(tail[..<stop])
                if bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
                name = String(decoding: bytes, as: UTF8.self)
            } else if name.hasSuffix("/") {
                // GNU short names end in "/" so they can contain spaces.
                name.removeLast()
            }

            if name.hasPrefix("__.SYMDEF") {
                hasSymbolIndex = true
                continue
            }
            if members.count >= limit {
                hitMemberLimit = true
                return
            }
            let mtime = Self.decimal(header[16..<28]) ?? 0
            let head = try file.read(at: dataStart, count: Int(min(dataSize, 64)))
            members.append(Member(name: name, size: dataSize,
                                  modified: mtime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(mtime)),
                                  architecture: Self.architecture(of: head)))
        }
    }

    /// What CPU an object member targets, from its first bytes.
    static func architecture(of head: [UInt8]) -> String? {
        if MachOInfo.isMachO(head) { return MachOHeader.architectures(in: head)?.first }
        if let elf = try? ELFHeader(head) { return elf.machineName }
        // LLVM bitcode, bare or in its wrapper header (-flto objects).
        if head.starts(with: [0x42, 0x43, 0xC0, 0xDE]) || head.starts(with: [0xDE, 0xC0, 0x17, 0x0B]) {
            return "LLVM bitcode"
        }
        return nil
    }

    /// A space-padded ASCII header field.
    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        var trimmed = bytes
        while let last = trimmed.last, last == 0x20 || last == 0 { trimmed.removeLast() }
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// A space-padded decimal field; nil when it holds anything else.
    private static func decimal(_ bytes: ArraySlice<UInt8>) -> UInt64? {
        var value: UInt64 = 0
        var digits = 0
        for byte in bytes {
            if byte == 0x20 || byte == 0 {
                if digits > 0 { break }
                continue
            }
            guard (0x30...0x39).contains(byte) else { return nil }
            let (shifted, overflow) = value.multipliedReportingOverflow(by: 10)
            guard !overflow else { return nil }
            value = shifted + UInt64(byte - 0x30)
            digits += 1
        }
        return digits > 0 ? value : nil
    }
}
