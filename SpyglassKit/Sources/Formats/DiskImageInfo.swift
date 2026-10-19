import Foundation

/// What a UDIF disk image (`.dmg`) says about itself without being mounted:
/// its `koly` trailer and the partition map in its XML plist.
public struct DiskImageInfo: Sendable {
    public var version: UInt32?
    /// hdiutil's format name: UDZO, UDBZ, ULFO, ULMO, UDCO or UDRO.
    public var format: String?
    public var compressedSize: UInt64?
    /// Size of the disk once mounted.
    public var expandedSize: UInt64?
    public var partitions: [String]
    public var isEncrypted: Bool
    /// True when the trailer points at an embedded code signature.
    public var isSigned: Bool
    /// The signature's details, when the Security framework can read them.
    public var signing: CodeSignature.Status?

    static let plistLimit = 32 << 20

    /// A description of a format name, for display.
    public static func describe(format: String) -> String? {
        switch format {
        case "UDZO": return "zlib-compressed"
        case "UDBZ": return "bzip2-compressed"
        case "ULFO": return "LZFSE-compressed"
        case "ULMO": return "LZMA-compressed"
        case "UDCO": return "ADC-compressed"
        case "UDRO": return "read-only, uncompressed"
        default: return nil
        }
    }

    public static func read(at url: URL) throws -> DiskImageInfo {
        let file = try FileBytes(url: url)
        var info = DiskImageInfo(partitions: [], isEncrypted: false, isSigned: false)
        // Encrypted images hide the trailer inside the encrypted data.
        if try file.read(at: 0, count: 8) == Array("encrcdsa".utf8)
            || (file.size >= 8 && file.read(at: file.size - 8, count: 8) == Array("cdsaencr".utf8)) {
            info.isEncrypted = true
            return info
        }
        guard file.size >= 512 else { throw ArchiveError.unrecognized("Not a UDIF disk image") }
        let trailer = try file.readExactly(at: file.size - 512, count: 512, "disk image trailer")
        let koly = try trailer.withUnsafeBytes { buffer -> Koly in
            var cursor = ByteCursor(buffer)
            guard try cursor.u32be() == 0x6B6F_6C79 else {        // "koly"
                throw ArchiveError.unrecognized("Not a UDIF disk image")
            }
            return try Koly(buffer)
        }

        info.version = koly.version
        info.compressedSize = koly.dataForkLength
        if koly.sectorCount > 0 { info.expandedSize = koly.sectorCount &* 512 }
        info.isSigned = koly.codeSignatureLength > 0
        if info.isSigned { info.signing = CodeSignature.read(at: url) }

        if koly.plistLength > 0, koly.plistLength <= UInt64(plistLimit),
           koly.plistOffset <= file.size, koly.plistLength <= file.size - koly.plistOffset,
           let xml = try? file.readExactly(at: koly.plistOffset, count: Int(koly.plistLength), "partition map"),
           let plist = try? PropertyListSerialization.propertyList(from: Data(xml), format: nil) as? [String: Any],
           let blocks = (plist["resource-fork"] as? [String: Any])?["blkx"] as? [[String: Any]] {
            info.readPartitionMap(blocks)
        }
        return info
    }

    // MARK: - Partition map

    private mutating func readPartitionMap(_ blocks: [[String: Any]]) {
        var chunkCounts: [UInt32: Int] = [:]
        var names: [String] = []
        for block in blocks {
            if let name = (block["Name"] as? String) ?? (block["CFName"] as? String) {
                names.append(name)
            }
            if let data = block["Data"] as? Data {
                Self.countChunks(in: data, into: &chunkCounts)
            }
        }
        let compressed: [UInt32: String] = [
            0x8000_0004: "UDCO", 0x8000_0005: "UDZO", 0x8000_0006: "UDBZ",
            0x8000_0007: "ULFO", 0x8000_0008: "ULMO",
        ]
        if let (type, _) = chunkCounts.filter({ compressed[$0.key] != nil }).max(by: { $0.value < $1.value }) {
            format = compressed[type]
        } else if chunkCounts[0x0000_0001] != nil {
            format = "UDRO"
        }

        // Skip the partition-scheme bookkeeping and keep what holds data.
        let bookkeeping = ["Apple_Free", "MBR :", "GPT Header", "GPT Partition Data", "Primary GPT",
                           "Backup GPT", "Driver Descriptor Map", "Apple_partition_map", "DDM :"]
        let volumes = names.filter { name in !bookkeeping.contains { name.contains($0) } }
        partitions = (volumes.isEmpty ? names : volumes).map(Self.partitionName)
    }

    /// Tallies a `mish` block table's chunks by type.
    private static func countChunks(in data: Data, into counts: inout [UInt32: Int]) {
        data.withUnsafeBytes { buffer in
            var cursor = ByteCursor(buffer)
            guard (try? cursor.u32be()) == 0x6D69_7368,             // "mish"
                  (try? cursor.skip(196)) != nil,
                  let count = try? cursor.u32be() else { return }
            for _ in 0..<min(Int(count), buffer.count / 40) {
                guard let type = try? cursor.u32be(), (try? cursor.skip(36)) != nil else { return }
                counts[type, default: 0] += 1
            }
        }
    }

    /// "disk image (Apple_APFS : 4)" reads as "disk image (APFS)".
    static func partitionName(_ raw: String) -> String {
        guard raw.hasSuffix(")"), let open = raw.lastIndex(of: "(") else { return raw }
        let label = raw[..<open].trimmingCharacters(in: .whitespaces)
        var type = raw[raw.index(after: open)..<raw.index(before: raw.endIndex)]
        if let colon = type.firstIndex(of: ":") { type = type[..<colon] }
        var scheme = type.trimmingCharacters(in: .whitespaces)
        if scheme.hasPrefix("Apple_") { scheme.removeFirst("Apple_".count) }
        if scheme.isEmpty { return label.isEmpty ? raw : label }
        return label.isEmpty ? scheme : "\(label) (\(scheme))"
    }

    /// The fields of the 512-byte UDIF trailer this reader uses.
    private struct Koly {
        var version: UInt32
        var dataForkLength: UInt64
        var plistOffset: UInt64
        var plistLength: UInt64
        var codeSignatureLength: UInt64
        var sectorCount: UInt64

        init(_ buffer: UnsafeRawBufferPointer) throws {
            func u32(_ offset: Int) throws -> UInt32 {
                var cursor = ByteCursor(buffer, offset: offset)
                return try cursor.u32be()
            }
            func u64(_ offset: Int) throws -> UInt64 {
                var cursor = ByteCursor(buffer, offset: offset)
                return try cursor.u64be()
            }
            version = try u32(0x004)
            dataForkLength = try u64(0x020)
            plistOffset = try u64(0x0D8)
            plistLength = try u64(0x0E0)
            codeSignatureLength = try u64(0x130)
            sectorCount = try u64(0x1EC)
        }
    }
}
