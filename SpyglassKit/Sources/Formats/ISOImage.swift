import Foundation

/// Lists an ISO 9660 disc image from its directory records, preferring the
/// Joliet tree (Unicode names) when the image has one. Nothing is mounted;
/// only volume descriptors and directories are read.
public enum ISOImage {
    /// Folders nested deeper than this aren't opened.
    static let maxDepth = 64
    /// Directory bytes one listing may read in all.
    static let maxDirectoryBytes: UInt64 = 64 << 20

    public static func list(_ url: URL, limits: ArchiveLimits = .standard) throws -> ArchiveListing {
        let file = try FileBytes(url: url)
        let volume = try findVolume(in: file)
        let deadline = monotonicSeconds() + limits.maxDuration

        struct Folder { var extent: UInt64; var size: UInt64; var path: String; var depth: Int }
        var queue = [Folder(extent: volume.root.extent, size: volume.root.size, path: "", depth: 0)]
        var visited: Set<UInt64> = [volume.root.extent]
        var entries: [ArchiveEntry] = []
        var incomplete: ArchiveListing.Incomplete?
        var bytesRead: UInt64 = 0
        var next = 0

        walk: while next < queue.count {
            let folder = queue[next]
            next += 1
            guard monotonicSeconds() <= deadline, bytesRead + folder.size <= maxDirectoryBytes else {
                incomplete = .workLimit(decompressedBytes: bytesRead)
                break
            }
            let data = try file.read(at: folder.extent * volume.blockSize, count: Int(folder.size))
            bytesRead += UInt64(data.count)
            if data.count < folder.size {
                incomplete = .damaged("The image ends inside a folder's records")
            }
            // Files bigger than one extent span several records with the
            // same name; all but the last carry the multi-extent flag.
            var pendingSizes: [String: UInt64] = [:]
            var offset = 0
            while offset < data.count {
                let length = Int(data[offset])
                if length == 0 {
                    // Records never cross a sector; zeros pad to the next one.
                    offset = (offset / Int(volume.blockSize) + 1) * Int(volume.blockSize)
                    continue
                }
                guard length >= 34, offset + length <= data.count,
                      let record = DirectoryRecord(data[offset..<(offset + length)], joliet: volume.isJoliet) else {
                    incomplete = .damaged("A folder's records are damaged")
                    break
                }
                offset += length
                guard let name = record.name, !record.isAssociated else { continue }
                let path = folder.path.isEmpty ? name : folder.path + "/" + name
                if record.isDirectory {
                    entries.append(ArchiveEntry(path: path, kind: .directory, modified: record.recorded))
                    if folder.depth + 1 < maxDepth, visited.insert(record.extent).inserted {
                        queue.append(Folder(extent: record.extent, size: record.size, path: path, depth: folder.depth + 1))
                    }
                } else if record.continues {
                    pendingSizes[path, default: 0] &+= record.size
                    continue
                } else {
                    let size = pendingSizes.removeValue(forKey: path).map { $0 &+ record.size } ?? record.size
                    entries.append(ArchiveEntry(path: path, kind: .file, size: size, modified: record.recorded))
                }
                if entries.count >= limits.maxEntries {
                    incomplete = .entryLimit(total: nil)
                    break walk
                }
            }
        }
        if entries.isEmpty, case .damaged(let reason)? = incomplete { throw ArchiveError.corrupt(reason) }
        return ArchiveListing(entries: entries, incomplete: incomplete, volumeName: volume.name)
    }

    // MARK: - Volume descriptors

    struct Volume {
        var name: String?
        var blockSize: UInt64
        var root: DirectoryRecord
        var isJoliet: Bool
    }

    /// The Joliet volume when the image has one, else the primary volume.
    static func findVolume(in file: FileBytes) throws -> Volume {
        var primary: Volume?
        var joliet: Volume?
        var sawUDF = false
        // Descriptors start at sector 16 and end with a terminator.
        for index in UInt64(0)..<64 {
            let sector = try file.read(at: (16 + index) * 2048, count: 2048)
            guard sector.count == 2048 else { break }
            let identifier = String(decoding: sector[1..<6], as: UTF8.self)
            if identifier == "CD001" {
                if sector[0] == 255 { break }
                if sector[0] == 1, primary == nil {
                    primary = try descriptor(sector, joliet: false)
                } else if sector[0] == 2, joliet == nil, sector[88] == 0x25, sector[89] == 0x2F,
                          [0x40, 0x43, 0x45].contains(sector[90]) {
                    // A supplementary descriptor with a UCS-2 escape sequence.
                    joliet = try descriptor(sector, joliet: true)
                }
            } else if ["BEA01", "NSR02", "NSR03", "TEA01", "BOOT2"].contains(identifier) {
                // UDF's volume recognition sequence.
                sawUDF = true
            } else {
                break
            }
        }
        if var volume = joliet ?? primary {
            if volume.name == nil { volume.name = primary?.name }
            return volume
        }
        if sawUDF { throw ArchiveError.unsupported("UDF disc images aren't supported") }
        throw ArchiveError.unrecognized("Not an ISO 9660 disc image")
    }

    private static func descriptor(_ sector: [UInt8], joliet: Bool) throws -> Volume {
        let blockSize = UInt64(sector[128]) | UInt64(sector[129]) << 8
        guard [512, 1024, 2048].contains(blockSize) else {
            throw ArchiveError.corrupt("The disc image's block size is invalid")
        }
        guard let root = DirectoryRecord(sector[156..<190], joliet: joliet), root.isDirectory else {
            throw ArchiveError.corrupt("The disc image's root folder record is damaged")
        }
        let name = decodeName(sector[40..<72], joliet: joliet)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        return Volume(name: name.isEmpty ? nil : name, blockSize: blockSize, root: root, isJoliet: joliet)
    }

    // MARK: - Directory records

    struct DirectoryRecord {
        var extent: UInt64
        var size: UInt64
        var recorded: Date?
        var isDirectory: Bool
        /// A Mac resource fork or other associated file.
        var isAssociated: Bool
        /// More extents of the same file follow.
        var continues: Bool
        /// nil for a folder's own "." and ".." records.
        var name: String?

        init?(_ bytes: ArraySlice<UInt8>, joliet: Bool) {
            let base = bytes.startIndex
            guard bytes.count >= 34 else { return nil }
            func le32(_ at: Int) -> UInt64 {
                UInt64(bytes[base + at]) | UInt64(bytes[base + at + 1]) << 8
                    | UInt64(bytes[base + at + 2]) << 16 | UInt64(bytes[base + at + 3]) << 24
            }
            let attributeBlocks = UInt64(bytes[base + 1])
            extent = le32(2) + attributeBlocks
            size = le32(10)
            recorded = ISOImage.date(bytes[(base + 18)..<(base + 25)])
            let flags = bytes[base + 25]
            isDirectory = flags & 0x02 != 0
            isAssociated = flags & 0x04 != 0
            continues = flags & 0x80 != 0
            let nameLength = Int(bytes[base + 32])
            guard 33 + nameLength <= bytes.count else { return nil }
            let raw = bytes[(base + 33)..<(base + 33 + nameLength)]
            if nameLength == 0 || (nameLength == 1 && raw.first! <= 1) {
                name = nil
            } else {
                name = ISOImage.cleanName(ISOImage.decodeName(raw, joliet: joliet), isDirectory: isDirectory)
            }
        }
    }

    static func decodeName(_ raw: ArraySlice<UInt8>, joliet: Bool) -> String {
        if joliet {
            return String(bytes: raw.prefix(raw.count & ~1), encoding: .utf16BigEndian) ?? ""
        }
        return String(bytes: raw, encoding: .utf8) ?? String(bytes: raw, encoding: .isoLatin1) ?? ""
    }

    /// Drops the ";1" version suffix and the dot of an empty extension.
    static func cleanName(_ name: String, isDirectory: Bool) -> String? {
        var name = Substring(name)
        if let semicolon = name.lastIndex(of: ";"), name[name.index(after: semicolon)...].allSatisfy(\.isNumber) {
            name = name[..<semicolon]
        }
        if !isDirectory, name.hasSuffix("."), name.count > 1 { name = name.dropLast() }
        return name.isEmpty ? nil : String(name)
    }

    /// A directory record's 7-byte recording time: years since 1900,
    /// month, day, hour, minute, second, then the offset from GMT in
    /// 15-minute steps.
    static func date(_ bytes: ArraySlice<UInt8>) -> Date? {
        let b = Array(bytes)
        guard b.count == 7, (1...12).contains(b[1]), (1...31).contains(b[2]), b[3] < 24, b[4] < 60, b[5] < 60 else {
            return nil
        }
        let zone = Int(Int8(bitPattern: b[6]))
        let days = daysFromCivil(year: 1900 + Int(b[0]), month: Int(b[1]), day: Int(b[2]))
        var seconds = days * 86_400 + Int(b[3]) * 3_600 + Int(b[4]) * 60 + Int(b[5])
        if (-48...52).contains(zone) { seconds -= zone * 15 * 60 }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
