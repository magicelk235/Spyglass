import Foundation
import MachO.dyld.utils

/// Architecture names from the start of a Mach-O executable: a fat header's
/// slice list, or a thin binary's one CPU type.
enum MachOHeader {
    /// How many leading bytes `architectures(in:)` needs at most.
    static let prefixLength = 8 + 64 * 32

    /// nil when the bytes aren't a Mach-O executable.
    static func architectures(in bytes: [UInt8]) -> [String]? {
        bytes.withUnsafeBytes { buffer in
            var cursor = ByteCursor(buffer)
            guard let magic = try? cursor.u32be() else { return nil }
            switch magic {
            case 0xCAFE_BABE, 0xCAFE_BABF:
                // FAT_MAGIC / FAT_MAGIC_64. Java class files share CAFEBABE;
                // their "count" is a class version far above any real slice count.
                guard let count = try? cursor.u32be(), (1...64).contains(count) else { return nil }
                var names: [String] = []
                for _ in 0..<count {
                    guard let type = try? cursor.u32be(), let subtype = try? cursor.u32be() else { return nil }
                    guard (try? cursor.skip(magic == 0xCAFE_BABE ? 12 : 24)) != nil else { return nil }
                    names.append(name(type: type, subtype: subtype))
                }
                return names
            case 0xCEFA_EDFE, 0xCFFA_EDFE:
                // MH_MAGIC / MH_MAGIC_64 stored little-endian.
                var thin = ByteCursor(buffer, offset: 4)
                guard let type = try? thin.u32le(), let subtype = try? thin.u32le() else { return nil }
                return [name(type: type, subtype: subtype)]
            case 0xFEED_FACE, 0xFEED_FACF:
                // Big-endian (PowerPC) binaries.
                guard let type = try? cursor.u32be(), let subtype = try? cursor.u32be() else { return nil }
                return [name(type: type, subtype: subtype)]
            default:
                return nil
            }
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
