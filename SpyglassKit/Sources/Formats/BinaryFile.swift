import Foundation

/// What a file routed as `.binary` turns out to be, decided by its leading
/// bytes rather than its name: `.so` files can be Mach-O bundles, and an
/// extensionless executable is often a script.
public enum BinaryFile: Sendable {
    case machO(MachOInfo)
    case staticLibrary(StaticLibrary)
    case elf(ELFHeader)
    /// Text, such as a shell script. `language` comes from its `#!` line.
    case script(language: String?)

    public static func inspect(_ url: URL) throws -> BinaryFile {
        let file = try FileBytes(url: url)
        let head = try file.read(at: 0, count: 4096)
        if StaticLibrary.isArchive(head) {
            return .staticLibrary(try StaticLibrary.read(at: url))
        }
        if let fat = try FatHeader(head, fileSize: file.size) {
            // A universal static library wraps one ar archive per architecture.
            if try file.read(at: fat.slices[0].offset, count: StaticLibrary.magic.count) == StaticLibrary.magic {
                return .staticLibrary(try StaticLibrary.read(file, fat: fat))
            }
            return .machO(try MachOInfo.read(file, fat: fat))
        }
        if MachOInfo.isMachO(head) {
            return .machO(MachOInfo(slices: [try MachOSlice.read(file, offset: 0, size: file.size)], isUniversal: false))
        }
        if ELFHeader.isELF(head) {
            return .elf(try ELFHeader.read(at: url))
        }
        if let text = TextSniffer.decode(Data(head)) {
            return .script(language: Shebang.language(for: text))
        }
        throw ArchiveError.unrecognized("Not a Mach-O, ELF or text file")
    }
}
