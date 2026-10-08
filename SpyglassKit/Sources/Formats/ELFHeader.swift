import Foundation

/// The identification fields of an ELF file's header: enough to say what
/// a Linux `.so` or object is built for. Dynamic sections aren't read.
public struct ELFHeader: Equatable, Sendable {
    public enum FileType: Equatable, Sendable {
        case relocatable, executable, sharedObject, core
        /// `ET_DYN` with a program interpreter: a PIE executable.
        case positionIndependentExecutable
        case other(UInt16)

        public var displayName: String {
            switch self {
            case .relocatable: return "Relocatable object"
            case .executable: return "Executable"
            case .sharedObject: return "Shared object"
            case .positionIndependentExecutable: return "Position-independent executable"
            case .core: return "Core dump"
            case .other(let raw): return String(format: "ELF file type %#x", UInt32(raw))
            }
        }
    }

    public var is64Bit: Bool
    public var isBigEndian: Bool
    public var fileType: FileType
    public var machine: UInt16
    public var osABI: UInt8

    static let magic: [UInt8] = [0x7F, 0x45, 0x4C, 0x46]

    static func isELF(_ head: [UInt8]) -> Bool {
        head.starts(with: magic)
    }

    /// Parses the header at the start of `bytes`. A shared object (`ET_DYN`)
    /// stays `.sharedObject`; `read(at:)` checks its program headers.
    init(_ bytes: [UInt8]) throws {
        guard bytes.starts(with: Self.magic) else { throw ArchiveError.unrecognized("Not an ELF file") }
        guard bytes.count >= 20 else { throw ArchiveError.truncated("The file ends inside the ELF header") }
        switch bytes[4] {
        case 1: is64Bit = false
        case 2: is64Bit = true
        default: throw ArchiveError.corrupt("The ELF class is invalid")
        }
        switch bytes[5] {
        case 1: isBigEndian = false
        case 2: isBigEndian = true
        default: throw ArchiveError.corrupt("The ELF byte order is invalid")
        }
        guard bytes.count >= (is64Bit ? 64 : 52) else {
            throw ArchiveError.truncated("The file ends inside the ELF header")
        }
        osABI = bytes[7]
        let big = isBigEndian
        let (type, machine) = try bytes.withUnsafeBytes { buffer in
            var cursor = ByteCursor(buffer, offset: 16)
            return (try cursor.u16(big), try cursor.u16(big))
        }
        self.machine = machine
        switch type {
        case 1: fileType = .relocatable
        case 2: fileType = .executable
        case 3: fileType = .sharedObject
        case 4: fileType = .core
        default: fileType = .other(type)
        }
    }

    /// The header of the ELF file at `url`. A shared object that names a
    /// program interpreter is reported as a PIE executable; when its
    /// program headers can't be read it stays a shared object.
    public static func read(at url: URL) throws -> ELFHeader {
        let file = try FileBytes(url: url)
        var header = try ELFHeader(try file.read(at: 0, count: 64))
        if header.fileType == .sharedObject, (try? header.hasInterpreter(in: file)) == true {
            header.fileType = .positionIndependentExecutable
        }
        return header
    }

    /// Whether a `PT_INTERP` program header exists.
    private func hasInterpreter(in file: FileBytes) throws -> Bool {
        let fields = try file.readExactly(at: 0, count: is64Bit ? 64 : 52, "ELF header")
        let big = isBigEndian
        let (tableOffset, entrySize, count) = try fields.withUnsafeBytes { buffer in
            var cursor = ByteCursor(buffer, offset: is64Bit ? 32 : 28)
            let offset = is64Bit ? try cursor.u64(big) : UInt64(try cursor.u32(big))
            try cursor.skip(is64Bit ? 8 + 4 + 2 : 4 + 4 + 2)   // e_shoff, e_flags, e_ehsize
            return (offset, Int(try cursor.u16(big)), Int(try cursor.u16(big)))
        }
        guard count > 0, count <= 4096, (4...256).contains(entrySize) else { return false }
        let table = try file.readExactly(at: tableOffset, count: entrySize * count, "program headers")
        return try table.withUnsafeBytes { buffer in
            for index in 0..<count {
                var cursor = ByteCursor(buffer, offset: index * entrySize)
                if try cursor.u32(big) == 3 { return true }    // PT_INTERP
            }
            return false
        }
    }

    public var machineName: String {
        switch machine {
        case 0x02: return "SPARC"
        case 0x03: return "x86"
        case 0x08: return "MIPS"
        case 0x14: return "PowerPC"
        case 0x15: return "PowerPC 64-bit"
        case 0x16: return "IBM S/390"
        case 0x28: return "ARM"
        case 0x2A: return "SuperH"
        case 0x2B: return "SPARC V9"
        case 0x32: return "IA-64"
        case 0x3E: return "x86-64"
        case 0xB7: return "AArch64"
        case 0xF3: return "RISC-V"
        case 0xF7: return "BPF"
        case 0x102: return "LoongArch"
        default: return String(format: "Machine %#x", UInt32(machine))
        }
    }

    /// nil for the generic System V ABI, which most files declare.
    public var osABIName: String? {
        switch osABI {
        case 0: return nil
        case 1: return "HP-UX"
        case 2: return "NetBSD"
        case 3: return "Linux"
        case 6: return "Solaris"
        case 9: return "FreeBSD"
        case 12: return "OpenBSD"
        case 97: return "ARM"
        case 255: return "Standalone"
        default: return "ABI \(osABI)"
        }
    }
}
