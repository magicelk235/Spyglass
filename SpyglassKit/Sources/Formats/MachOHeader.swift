import Foundation
import MachO.dyld.utils

/// Architecture names from the start of a Mach-O executable: a fat header's
/// slice list, or a thin binary's one CPU type. For callers that only have
/// the file's first bytes (a member inside an `.ipa`); `MachOInfo` reads
/// the rest of a file on disk.
enum MachOHeader {
    /// How many leading bytes `architectures(in:)` needs at most.
    static let prefixLength = FatHeader.maxLength

    /// nil when the bytes aren't a Mach-O executable.
    static func architectures(in bytes: [UInt8]) -> [String]? {
        if let fat = try? FatHeader(bytes, fileSize: nil) {
            return fat.slices.map(\.architecture)
        }
        guard bytes.count >= 12,
              let layout = MachOSlice.layout(forMagic: UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                                             | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) else {
            return nil
        }
        return bytes.withUnsafeBytes { buffer in
            var cursor = ByteCursor(buffer, offset: 4)
            guard let type = try? cursor.u32(layout.isBigEndian),
                  let subtype = try? cursor.u32(layout.isBigEndian) else { return nil }
            return [name(type: type, subtype: subtype)]
        }
    }

    static func name(type: UInt32, subtype: UInt32) -> String {
        if let name = macho_arch_name_for_cpu_type(cpu_type_t(bitPattern: type), cpu_subtype_t(bitPattern: subtype)) {
            return String(cString: name)
        }
        switch type {
        case 0x0100_000C: return "arm64"
        case 0x0100_0007: return "x86_64"
        case 0x0000_0007: return "i386"
        case 0x0000_000C: return "arm"
        case 0x0000_0012: return "ppc"
        case 0x0100_0012: return "ppc64"
        default: return String(format: "cpu %#x", type)
        }
    }
}
