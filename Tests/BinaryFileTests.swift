import XCTest
@testable import SpyglassKit

/// Static libraries, ELF headers, and telling them apart from Mach-O files
/// and scripts.
final class BinaryFileTests: ArchiveTestCase {

    /// Compiles `source` to an object file with clang.
    private func object(_ name: String, _ source: String, _ arguments: [String]) throws -> URL {
        let input = try write("src/\(name).c", source)
        let output = dir.appendingPathComponent(name)
        try run("/usr/bin/clang", ["-c"] + arguments + ["-o", output.path, input.path])
        return output
    }

    /// A 60-byte ar member header.
    private func arHeader(_ name: String, size: Int, mtime: Int = 1_700_000_000, fmag: [UInt8] = [0x60, 0x0A]) -> [UInt8] {
        func field(_ text: String, _ width: Int) -> [UInt8] {
            Array(text.utf8) + [UInt8](repeating: 0x20, count: width - text.utf8.count)
        }
        return field(name, 16) + field("\(mtime)", 12) + field("0", 6) + field("0", 6) + field("100644", 8)
            + field("\(size)", 10) + fmag
    }

    /// A header plus data, padded to an even length.
    private func arMember(_ name: String, _ data: [UInt8], mtime: Int = 1_700_000_000) -> [UInt8] {
        arHeader(name, size: data.count, mtime: mtime) + data + (data.count % 2 == 1 ? [0x0A] : [])
    }

    /// The fixed part of an ELF header, plus program headers of the given types.
    private func elf(is64Bit: Bool = true, bigEndian: Bool = false, type: UInt16, machine: UInt16,
                     osABI: UInt8 = 0, programTypes: [UInt32] = []) -> [UInt8] {
        var bytes: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, is64Bit ? 2 : 1, bigEndian ? 2 : 1, 1, osABI]
        bytes += [UInt8](repeating: 0, count: 8)
        func u16(_ value: UInt16) { bigEndian ? bytes.be16(value) : bytes.le16(value) }
        func u32(_ value: UInt32) { bigEndian ? bytes.be32(value) : bytes.le32(value) }
        func word(_ value: UInt64) { is64Bit ? (bigEndian ? bytes.be64(value) : bytes.le64(value)) : u32(UInt32(value)) }
        let headerSize: UInt16 = is64Bit ? 64 : 52
        let entrySize: UInt16 = is64Bit ? 56 : 32
        u16(type); u16(machine); u32(1)
        word(0)                                                     // e_entry
        word(programTypes.isEmpty ? 0 : UInt64(headerSize))          // e_phoff
        word(0)                                                     // e_shoff
        u32(0); u16(headerSize); u16(entrySize); u16(UInt16(programTypes.count)); u16(0); u16(0); u16(0)
        for programType in programTypes {
            u32(programType)
            bytes += [UInt8](repeating: 0, count: Int(entrySize) - 4)
        }
        return bytes
    }

    // MARK: - Static libraries

    func testReadsAStaticLibraryMadeByAr() throws {
        let first = try object("first.o", "int first(void) { return 1; }\n", ["-arch", "arm64"])
        let second = try object("a_member_with_a_long_name.o", "int second(void) { return 2; }\n", ["-arch", "arm64"])
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for url in [first, second] {
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        }
        try run("/usr/bin/ar", ["rcs", "libpair.a", first.lastPathComponent, second.lastPathComponent])

        let library = try StaticLibrary.read(at: dir.appendingPathComponent("libpair.a"))
        XCTAssertFalse(library.isUniversal)
        XCTAssertTrue(library.hasSymbolIndex)
        XCTAssertFalse(library.hitMemberLimit)
        XCTAssertEqual(library.architectures, ["arm64"])
        XCTAssertEqual(library.members.map(\.name), ["first.o", "a_member_with_a_long_name.o"])
        XCTAssertEqual(library.members.map(\.size), try [first, second].map { UInt64(try Data(contentsOf: $0).count) })
        XCTAssertEqual(library.members.map(\.modified), [stamp, stamp])
        XCTAssertEqual(library.members.map(\.architecture), ["arm64", "arm64"])
    }

    func testArchiveWithoutRanlibHasNoSymbolIndex() throws {
        let member = try object("only.o", "int only(void) { return 1; }\n", ["-arch", "x86_64"])
        try run("/usr/bin/ar", ["rcS", "libplain.a", member.lastPathComponent])
        let library = try StaticLibrary.read(at: dir.appendingPathComponent("libplain.a"))
        XCTAssertFalse(library.hasSymbolIndex)
        XCTAssertEqual(library.members.map(\.name), ["only.o"])
        XCTAssertEqual(library.architectures, ["x86_64"])
    }

    func testUniversalStaticLibraryListsEachSlice() throws {
        for arch in ["arm64", "x86_64"] {
            let one = try object("one-\(arch).o", "int one(void) { return 1; }\n", ["-arch", arch])
            let two = try object("two-\(arch).o", "int two(void) { return 2; }\n", ["-arch", arch])
            try run("/usr/bin/ar", ["rcs", "lib-\(arch).a", one.lastPathComponent, two.lastPathComponent])
        }
        try run("/usr/bin/lipo", ["-create", "lib-arm64.a", "lib-x86_64.a", "-output", "libfat.a"])
        let url = dir.appendingPathComponent("libfat.a")
        let library = try StaticLibrary.read(at: url)
        XCTAssertTrue(library.isUniversal)
        let lipo = String(decoding: try run("/usr/bin/lipo", ["-archs", url.path]), as: UTF8.self)
        XCTAssertEqual(library.architectures, lipo.split(whereSeparator: \.isWhitespace).map(String.init))
        XCTAssertEqual(library.members.count, 4)
        for member in library.members {
            XCTAssertTrue(member.name.hasSuffix("-\(member.architecture ?? "?").o"), member.name)
        }
        guard case .staticLibrary(let inspected) = try BinaryFile.inspect(url) else { return XCTFail("not a library") }
        XCTAssertEqual(inspected, library)
    }

    func testMemberLimit() throws {
        let data = Array("not an object".utf8)
        var bytes = StaticLibrary.magic
        for index in 0..<10 { bytes += arMember("m\(index).txt", data) }
        let library = try StaticLibrary.read(at: try write("many.a", Data(bytes)), memberLimit: 4)
        XCTAssertEqual(library.members.map(\.name), ["m0.txt", "m1.txt", "m2.txt", "m3.txt"])
        XCTAssertTrue(library.hitMemberLimit)
        XCTAssertEqual(library.members.first?.architecture, nil)
    }

    func testGNUArchiveNamesAndSymbolTable() throws {
        let names = Array("a_rather_long_object_name.o/\nsecond_long_object_name.o/\n".utf8)
        let x86 = elf(type: 1, machine: 0x3E)
        let arm = elf(type: 1, machine: 0xB7)
        var bytes = StaticLibrary.magic
        bytes += arMember("/", [0, 0, 0, 0])
        bytes += arMember("//", names)
        bytes += arMember("/0", x86)
        bytes += arMember("/29", arm)
        bytes += arMember("short.o/", x86, mtime: 0)
        let library = try StaticLibrary.read(at: try write("libgnu.a", Data(bytes)))
        XCTAssertTrue(library.hasSymbolIndex)
        XCTAssertEqual(library.members.map(\.name), ["a_rather_long_object_name.o", "second_long_object_name.o", "short.o"])
        XCTAssertEqual(library.members.map(\.architecture), ["x86-64", "AArch64", "x86-64"])
        XCTAssertEqual(library.architectures, ["x86-64", "AArch64"])
        XCTAssertEqual(library.members.map(\.size), [64, 64, 64])
        XCTAssertNil(library.members.last?.modified)
    }

    func testDamagedArchivesThrow() throws {
        let member = arMember("ok.o", Array("data".utf8))
        func read(_ bytes: [UInt8]) throws -> StaticLibrary {
            try StaticLibrary.read(at: try write("lib-\(UUID().uuidString).a", Data(bytes)))
        }
        XCTAssertThrowsError(try read(Array(repetitiveText(100)))) { error in
            XCTAssertEqual(error as? ArchiveError, .unrecognized("Not a static library"))
        }
        XCTAssertThrowsError(try read(StaticLibrary.magic + Array(member.prefix(40)))) { error in
            XCTAssertEqual(error as? ArchiveError, .truncated("The archive ends inside a member header"))
        }
        XCTAssertThrowsError(try read(StaticLibrary.magic + arHeader("big.o", size: 5000) + [1, 2, 3])) { error in
            XCTAssertEqual(error as? ArchiveError, .truncated("The archive ends inside big.o"))
        }
        XCTAssertThrowsError(try read(StaticLibrary.magic + arHeader("bad.o", size: 4, fmag: [0x20, 0x20]) + [1, 2, 3, 4])) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupt("A member header is damaged"))
        }
        var badSize = arHeader("odd.o", size: 4)
        badSize[48] = UInt8(ascii: "x")
        XCTAssertThrowsError(try read(StaticLibrary.magic + badSize + [1, 2, 3, 4])) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupt("A member header has a bad size"))
        }
        XCTAssertThrowsError(try read(StaticLibrary.magic + arMember("#1/50", [1, 2, 3, 4]))) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupt("A member's long name is damaged"))
        }
        XCTAssertThrowsError(try read(StaticLibrary.magic + arMember("//", Array("x.o/\n".utf8)) + arMember("/99", [1, 2]))) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupt("A member's long name points outside the name table"))
        }
        // A trailing newline after the last member is padding, not damage.
        XCTAssertEqual(try read(StaticLibrary.magic + member + [0x0A]).members.map(\.name), ["ok.o"])
        XCTAssertEqual(try read(StaticLibrary.magic).members, [])
    }

    // MARK: - ELF

    func testELFObjectsBuiltForLinux() throws {
        let source = "int add(int a, int b) { return a + b; }\n"
        let cases: [(target: String, is64Bit: Bool, bigEndian: Bool, machine: String)] = [
            ("x86_64-unknown-linux-gnu", true, false, "x86-64"),
            ("i386-unknown-linux-gnu", false, false, "x86"),
            ("aarch64_be-unknown-linux-gnu", true, true, "AArch64"),
        ]
        for item in cases {
            let url = try object("add-\(item.target).o", source, ["-target", item.target])
            let header = try ELFHeader.read(at: url)
            XCTAssertEqual(header.is64Bit, item.is64Bit, item.target)
            XCTAssertEqual(header.isBigEndian, item.bigEndian, item.target)
            XCTAssertEqual(header.machineName, item.machine, item.target)
            XCTAssertEqual(header.fileType, .relocatable, item.target)
            guard case .elf(let inspected) = try BinaryFile.inspect(url) else { return XCTFail(item.target) }
            XCTAssertEqual(inspected, header)
        }
    }

    func testSharedObjectsAndPIEExecutables() throws {
        let library = try ELFHeader.read(at: try write("libx.so", Data(elf(type: 3, machine: 0xB7, programTypes: [1, 2]))))
        XCTAssertEqual(library.fileType, .sharedObject)
        XCTAssertEqual(library.fileType.displayName, "Shared object")
        let pie = try ELFHeader.read(at: try write("tool", Data(elf(type: 3, machine: 0x3E, osABI: 3, programTypes: [6, 3, 1]))))
        XCTAssertEqual(pie.fileType, .positionIndependentExecutable)
        XCTAssertEqual(pie.osABIName, "Linux")
        let old = try ELFHeader.read(at: try write("old", Data(elf(is64Bit: false, bigEndian: true, type: 2, machine: 0x14))))
        XCTAssertEqual(old.fileType, .executable)
        XCTAssertEqual(old.machineName, "PowerPC")
        XCTAssertTrue(old.isBigEndian)
        XCTAssertNil(old.osABIName)

        // Program headers past the end: the header still reads.
        var cut = elf(type: 3, machine: 0x3E, programTypes: [3])
        cut.removeLast(40)
        XCTAssertEqual(try ELFHeader.read(at: try write("cut.so", Data(cut))).fileType, .sharedObject)
    }

    func testDamagedELFHeadersThrow() throws {
        let header = elf(type: 1, machine: 0x3E)
        XCTAssertThrowsError(try ELFHeader.read(at: try write("short.so", Data(header.prefix(40))))) { error in
            XCTAssertEqual(error as? ArchiveError, .truncated("The file ends inside the ELF header"))
        }
        var badClass = header
        badClass[4] = 9
        XCTAssertThrowsError(try ELFHeader.read(at: try write("class.so", Data(badClass)))) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupt("The ELF class is invalid"))
        }
        var badOrder = header
        badOrder[5] = 0
        XCTAssertThrowsError(try ELFHeader.read(at: try write("order.so", Data(badOrder)))) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupt("The ELF byte order is invalid"))
        }
        // A 32-bit header is 52 bytes, a 64-bit one 64.
        let small = elf(is64Bit: false, type: 1, machine: 3)
        XCTAssertEqual(small.count, 52)
        XCTAssertEqual(try ELFHeader.read(at: try write("small.o", Data(small))).machineName, "x86")
    }

    // MARK: - Telling files apart

    func testInspectSendsScriptsToTheCodeView() throws {
        let python = try write("tool", "#!/usr/bin/env python3\nprint('hi')\n")
        guard case .script(let language) = try BinaryFile.inspect(python) else { return XCTFail("not a script") }
        XCTAssertEqual(language, "python")

        let plain = try write("notes", "just some text\n")
        guard case .script(let none) = try BinaryFile.inspect(plain) else { return XCTFail("not a script") }
        XCTAssertNil(none)

        var noise = [UInt8](repeating: 0, count: 300)
        for index in noise.indices { noise[index] = UInt8(truncatingIfNeeded: index &* 151 &+ 7) }
        XCTAssertThrowsError(try BinaryFile.inspect(try write("blob", Data(noise)))) { error in
            XCTAssertEqual(error as? ArchiveError, .unrecognized("Not a Mach-O, ELF or text file"))
        }
    }

    func testInspectsTheSampleFixtures() throws {
        guard case .staticLibrary(let library) = try BinaryFile.inspect(fixture("libsample.a")) else {
            return XCTFail("libsample.a")
        }
        XCTAssertTrue(library.isUniversal)
        XCTAssertEqual(library.architectures, ["x86_64", "arm64"])
        XCTAssertEqual(library.members.map(\.name), ["x86-add.o", "x86-twice.o", "arm-add.o", "arm-twice.o"])
        XCTAssertEqual(library.members.map(\.architecture), ["x86_64", "x86_64", "arm64", "arm64"])
        XCTAssertTrue(library.members.allSatisfy { $0.modified == nil })   // written with ZERO_AR_DATE

        guard case .machO(let object) = try BinaryFile.inspect(fixture("sample.o")) else { return XCTFail("sample.o") }
        XCTAssertEqual(object.slices.map(\.fileType), [.object])

        guard case .script(let language) = try BinaryFile.inspect(fixture("run-tests")) else {
            return XCTFail("run-tests")
        }
        XCTAssertEqual(language, "bash")
    }

    func testInspectFindsMachOAndStaticLibraries() throws {
        let objectFile = try object("piece.o", "int piece(void) { return 3; }\n", ["-arch", "arm64"])
        guard case .machO(let info) = try BinaryFile.inspect(objectFile) else { return XCTFail("not Mach-O") }
        XCTAssertEqual(info.slices.first?.fileType, .object)
        try run("/usr/bin/ar", ["rcs", "libpiece.a", objectFile.lastPathComponent])
        guard case .staticLibrary(let library) = try BinaryFile.inspect(dir.appendingPathComponent("libpiece.a")) else {
            return XCTFail("not a static library")
        }
        XCTAssertEqual(library.members.map(\.name), ["piece.o"])
    }
}
