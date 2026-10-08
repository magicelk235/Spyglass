import XCTest
@testable import SpyglassKit

final class MachOInfoTests: ArchiveTestCase {

    private let mainSource = "int main(void) { return 0; }\n"

    /// Compiles `source` with clang into the scratch folder.
    private func compile(_ name: String, _ source: String, _ arguments: [String]) throws -> URL {
        let input = try write("src/\(name).c", source)
        let output = dir.appendingPathComponent(name)
        try run("/usr/bin/clang", arguments + ["-o", output.path, input.path])
        return output
    }

    private func lipoArchitectures(_ url: URL) throws -> [String] {
        String(decoding: try run("/usr/bin/lipo", ["-archs", url.path]), as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// UUIDs by architecture, as dwarfdump reports them.
    private func dwarfdumpUUIDs(_ url: URL) throws -> [String: UUID] {
        let output = String(decoding: try run("/usr/bin/dwarfdump", ["--uuid", url.path]), as: UTF8.self)
        var uuids: [String: UUID] = [:]
        for line in output.split(separator: "\n") {
            let words = line.split(separator: " ")
            guard words.count >= 3, words[0] == "UUID:", let uuid = UUID(uuidString: String(words[1])) else { continue }
            uuids[words[2].trimmingCharacters(in: CharacterSet(charactersIn: "()"))] = uuid
        }
        return uuids
    }

    // MARK: - Compiled binaries

    func testThinExecutable() throws {
        let url = try compile("tool", mainSource, ["-arch", "arm64", "-mmacosx-version-min=12.3"])
        let info = try MachOInfo.read(at: url)
        XCTAssertFalse(info.isUniversal)
        XCTAssertEqual(info.slices.count, 1)
        let slice = info.slices[0]
        XCTAssertEqual(slice.architecture, "arm64")
        XCTAssertEqual(slice.fileType, .executable)
        XCTAssertTrue(slice.is64Bit)
        XCTAssertFalse(slice.isBigEndian)
        XCTAssertTrue(slice.hasMain)
        XCTAssertEqual(Array(slice.notableFlags.prefix(2)), ["PIE", "Two-level namespace"])
        XCTAssertEqual(slice.buildVersions.count, 1)
        XCTAssertEqual(slice.buildVersions.first?.platform, "macOS")
        XCTAssertEqual(slice.buildVersions.first?.minimumOS, "12.3")
        XCTAssertNotNil(slice.buildVersions.first?.sdk)
        XCTAssertEqual(slice.uuid, try dwarfdumpUUIDs(url)["arm64"])
        XCTAssertEqual(slice.libraries.map(\.path), ["/usr/lib/libSystem.B.dylib"])
        XCTAssertNil(slice.identity)
        XCTAssertEqual(slice.rpaths, [])
        XCTAssertNil(slice.isEncrypted)
        XCTAssertEqual(slice.offset, 0)
        XCTAssertEqual(slice.size, UInt64(try Data(contentsOf: url).count))

        let pageZero = try XCTUnwrap(slice.segments.first)
        XCTAssertEqual(pageZero.name, "__PAGEZERO")
        XCTAssertEqual(pageZero.fileSize, 0)
        XCTAssertEqual(pageZero.vmSize, 1 << 32)
        XCTAssertEqual(slice.segments.last?.name, "__LINKEDIT")
        XCTAssertTrue(slice.segments.contains { $0.name == "__TEXT" && $0.sections.contains { $0.name == "__text" } })

        // ld signs arm64 output ad hoc.
        XCTAssertTrue(slice.hasCodeSignature)
        guard case .signed(let signature)? = CodeSignature.read(at: url) else { return XCTFail("not signed") }
        XCTAssertTrue(signature.isAdHoc)
        XCTAssertTrue(signature.isLinkerSigned)
        XCTAssertFalse(signature.isHardenedRuntime)
    }

    func testSigningDetailsOfAStandaloneBinary() throws {
        let url = try compile("signed", mainSource, ["-arch", "arm64"])
        let entitlements = try write("tool.entitlements", try PropertyListSerialization.data(
            fromPropertyList: ["com.apple.security.cs.disable-library-validation": true], format: .xml, options: 0))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", "--identifier", "com.example.signed",
                                      "--entitlements", entitlements.path, url.path])
        guard case .signed(let signature)? = CodeSignature.read(at: url) else { return XCTFail("not signed") }
        XCTAssertTrue(signature.isAdHoc)
        XCTAssertFalse(signature.isLinkerSigned)
        XCTAssertTrue(signature.isHardenedRuntime)
        XCTAssertEqual(signature.identifier, "com.example.signed")
        XCTAssertEqual(signature.entitlements, [PropertyRow(key: "com.apple.security.cs.disable-library-validation", value: "true")])

        // An x86_64 slice gets no linker signature.
        let unsigned = try compile("unsigned", mainSource, ["-arch", "x86_64"])
        XCTAssertFalse(try MachOInfo.read(at: unsigned).slices[0].hasCodeSignature)
        XCTAssertEqual(CodeSignature.read(at: unsigned), .unsigned)
    }

    func testUniversalExecutable() throws {
        let url = try compile("fat", mainSource, ["-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=12.0"])
        let info = try MachOInfo.read(at: url)
        XCTAssertTrue(info.isUniversal)
        XCTAssertEqual(info.slices.map(\.architecture), try lipoArchitectures(url))
        let uuids = try dwarfdumpUUIDs(url)
        let fileSize = UInt64(try Data(contentsOf: url).count)
        for slice in info.slices {
            XCTAssertEqual(slice.fileType, .executable)
            XCTAssertEqual(slice.uuid, uuids[slice.architecture], slice.architecture)
            XCTAssertEqual(slice.buildVersions.first?.minimumOS, "12.0")
            XCTAssertGreaterThan(slice.offset, 0)
            XCTAssertLessThanOrEqual(slice.offset + slice.size, fileSize)
        }
        // Only the arm64 slice gets the linker's ad hoc signature.
        let signed = Dictionary(uniqueKeysWithValues: info.slices.map { ($0.architecture, $0.hasCodeSignature) })
        XCTAssertEqual(signed, ["arm64": true, "x86_64": false])
    }

    func testDylibIdentityRpathsAndLinkKinds() throws {
        let library = try compile("libanswer.dylib", "int answer(void) { return 42; }\n", [
            "-dynamiclib", "-arch", "arm64", "-install_name", "@rpath/libanswer.dylib",
            "-current_version", "1.2.3", "-compatibility_version", "1.0.0",
            "-Wl,-rpath,@loader_path/../Frameworks", "-Wl,-rpath,/opt/example/lib",
        ])
        let slice = try MachOInfo.read(at: library).slices[0]
        XCTAssertEqual(slice.fileType, .dylib)
        XCTAssertFalse(slice.hasMain)
        XCTAssertEqual(slice.identity, MachOSlice.Library(path: "@rpath/libanswer.dylib", kind: .normal,
                                                          currentVersion: "1.2.3", compatibilityVersion: "1.0.0"))
        XCTAssertEqual(slice.rpaths, ["@loader_path/../Frameworks", "/opt/example/lib"])

        let user = try compile("user", "int answer(void); int main(void) { return answer(); }\n", [
            "-arch", "arm64", "-L", dir.path, "-Wl,-weak-lanswer", "-framework", "CoreFoundation",
        ])
        let libraries = try MachOInfo.read(at: user).slices[0].libraries
        XCTAssertEqual(libraries.first, MachOSlice.Library(path: "@rpath/libanswer.dylib", kind: .weak,
                                                           currentVersion: "1.2.3", compatibilityVersion: "1.0.0"))
        XCTAssertTrue(libraries.contains { $0.path.hasSuffix("/CoreFoundation") && $0.kind == .normal })

        let wrapper = try compile("libwrapper.dylib", "int helper(void) { return 1; }\n", [
            "-dynamiclib", "-arch", "arm64", "-install_name", "@rpath/libwrapper.dylib",
            "-L", dir.path, "-Wl,-reexport-lanswer",
        ])
        let reexported = try MachOInfo.read(at: wrapper).slices[0].libraries.first { $0.path == "@rpath/libanswer.dylib" }
        XCTAssertEqual(reexported?.kind, .reexport)
    }

    func testObjectFileListsSectionsOfItsOneSegment() throws {
        let source = try write("src/answer.c", "int value = 7;\nint answer(void) { return value; }\n")
        let object = dir.appendingPathComponent("answer.o")
        try run("/usr/bin/clang", ["-c", "-arch", "arm64", "-mmacosx-version-min=13.0", "-o", object.path, source.path])
        let slice = try MachOInfo.read(at: object).slices[0]
        XCTAssertEqual(slice.fileType, .object)
        XCTAssertFalse(slice.hasCodeSignature)
        XCTAssertFalse(slice.hasMain)
        XCTAssertEqual(slice.libraries, [])
        XCTAssertEqual(slice.buildVersions.first?.minimumOS, "13.0")
        XCTAssertEqual(slice.segments.count, 1)
        XCTAssertEqual(slice.segments[0].name, "")
        let sections = slice.segments[0].sections
        XCTAssertGreaterThan(sections.first { $0.segment == "__TEXT" && $0.name == "__text" }?.size ?? 0, 0)
        XCTAssertEqual(sections.first { $0.segment == "__DATA" && $0.name == "__data" }?.size, 4)
    }

    func testOlderDeploymentTargetsUseVersionMinCommands() throws {
        let url = try compile("old", mainSource, ["-arch", "x86_64", "-mmacosx-version-min=10.13"])
        let slice = try MachOInfo.read(at: url).slices[0]
        XCTAssertEqual(slice.architecture, "x86_64")
        XCTAssertEqual(slice.buildVersions.map(\.platform), ["macOS"])
        XCTAssertEqual(slice.buildVersions.first?.minimumOS, "10.13")
    }

    func testReadsAnOnDiskSystemBinary() throws {
        let dyld = URL(fileURLWithPath: "/usr/lib/dyld")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dyld.path))
        let info = try MachOInfo.read(at: dyld)
        XCTAssertEqual(info.slices.map(\.architecture), try lipoArchitectures(dyld))
        XCTAssertTrue(info.slices.allSatisfy { $0.fileType == .dylinker })
    }

    // MARK: - Hand-built files

    /// A big-endian 32-bit (PowerPC) executable with the commands clang no
    /// longer writes for macOS: iOS version-min, encryption, a lazy dylib.
    private func bigEndianBinary() -> [UInt8] {
        var commands: [UInt8] = []
        commands.be32(0x1B); commands.be32(24)                        // LC_UUID
        commands += Array(0x10...0x1F)
        let name = Array("/usr/lib/libfake.dylib".utf8) + [0, 0]      // padded to 4 bytes
        commands.be32(0x20); commands.be32(UInt32(24 + name.count))   // LC_LAZY_LOAD_DYLIB
        commands.be32(24); commands.be32(0)
        commands.be32(0x0002_0301); commands.be32(0x0001_0000)       // 2.3.1, 1.0.0
        commands += name
        commands.be32(0x25); commands.be32(16)                        // LC_VERSION_MIN_IPHONEOS
        commands.be32(0x0009_0300); commands.be32(0)                  // 9.3, no SDK
        commands.be32(0x21); commands.be32(20)                        // LC_ENCRYPTION_INFO
        commands.be32(0x1000); commands.be32(0x2000); commands.be32(1)
        var file: [UInt8] = []
        file.be32(0xFEED_FACE); file.be32(18); file.be32(0); file.be32(2)
        file.be32(4); file.be32(UInt32(commands.count)); file.be32(0x85)
        return file + commands
    }

    func testBigEndianThirtyTwoBitSlice() throws {
        let slice = try MachOInfo.read(at: try write("ppc", Data(bigEndianBinary()))).slices[0]
        XCTAssertEqual(slice.architecture, "ppc")
        XCTAssertTrue(slice.isBigEndian)
        XCTAssertFalse(slice.is64Bit)
        XCTAssertEqual(slice.uuid, UUID(uuid: (0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
                                               0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F)))
        XCTAssertEqual(slice.libraries, [MachOSlice.Library(path: "/usr/lib/libfake.dylib", kind: .lazy,
                                                            currentVersion: "2.3.1", compatibilityVersion: "1.0.0")])
        XCTAssertEqual(slice.buildVersions, [MachOSlice.BuildVersion(platform: "iOS", minimumOS: "9.3", sdk: nil)])
        XCTAssertEqual(slice.isEncrypted, true)
        XCTAssertEqual(slice.notableFlags, ["Two-level namespace"])
    }

    func testFat64Header() throws {
        let thin = bigEndianBinary()
        var file: [UInt8] = []
        file.be32(0xCAFE_BABF); file.be32(1)
        file.be32(18); file.be32(0); file.be64(0x1000); file.be64(UInt64(thin.count)); file.be32(12); file.be32(0)
        file += [UInt8](repeating: 0, count: 0x1000 - file.count) + thin
        let info = try MachOInfo.read(at: try write("fat64", Data(file)))
        XCTAssertTrue(info.isUniversal)
        XCTAssertEqual(info.slices.map(\.architecture), ["ppc"])
        XCTAssertEqual(info.slices[0].offset, 0x1000)
        XCTAssertEqual(info.slices[0].size, UInt64(thin.count))
        XCTAssertEqual(info.slices[0].isEncrypted, true)
    }

    // MARK: - Damaged input

    func testTruncatedAndGarbageInputsThrow() throws {
        let url = try compile("tool", mainSource, ["-arch", "arm64"])
        let data = try Data(contentsOf: url)
        XCTAssertThrowsError(try MachOInfo.read(at: try write("empty", Data()))) { error in
            XCTAssertEqual(error as? ArchiveError, .unrecognized("Not a Mach-O file"))
        }
        XCTAssertThrowsError(try MachOInfo.read(at: try write("text", repetitiveText(4096)))) { error in
            XCTAssertEqual(error as? ArchiveError, .unrecognized("Not a Mach-O file"))
        }
        XCTAssertThrowsError(try MachOInfo.read(at: try write("cut-header", data.prefix(20)))) { error in
            XCTAssertEqual(error as? ArchiveError, .truncated("The file ends inside the Mach-O header"))
        }
        XCTAssertThrowsError(try MachOInfo.read(at: try write("cut-commands", data.prefix(300)))) { error in
            XCTAssertEqual(error as? ArchiveError, .truncated("The file ends inside the load commands"))
        }

        var zeroSize = [UInt8](data)
        zeroSize[36...39] = [0, 0, 0, 0]                               // first command's cmdsize
        XCTAssertThrowsError(try MachOInfo.read(at: try write("zero-size", Data(zeroSize)))) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupt("A load command has an impossible size"))
        }
        var tooMany = [UInt8](data)
        tooMany[16...19] = [0xFF, 0xFF, 0x00, 0x00]                    // ncmds
        XCTAssertThrowsError(try MachOInfo.read(at: try write("too-many", Data(tooMany)))) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupt("The header counts more load commands than fit"))
        }
        var hugeCommands = [UInt8](data)
        hugeCommands[20...23] = [0xFF, 0xFF, 0xFF, 0x7F]               // sizeofcmds
        XCTAssertThrowsError(try MachOInfo.read(at: try write("huge", Data(hugeCommands))))

        // A dylib name offset that points outside its command.
        var badName = bigEndianBinary()
        badName[28 + 24 + 8...28 + 24 + 11] = [0, 0, 0xFF, 0xFF]
        XCTAssertThrowsError(try MachOInfo.read(at: try write("bad-name", Data(badName)))) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupt("A load command's string lies outside it"))
        }
    }

    func testUniversalHeadersThatDontFitTheFileThrow() throws {
        let url = try compile("fat", mainSource, ["-arch", "arm64", "-arch", "x86_64"])
        let data = try Data(contentsOf: url)
        XCTAssertThrowsError(try MachOInfo.read(at: try write("fat-cut", data.prefix(data.count / 2)))) { error in
            guard case .truncated? = error as? ArchiveError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try MachOInfo.read(at: try write("fat-table-cut", data.prefix(20)))) { error in
            XCTAssertEqual(error as? ArchiveError, .truncated("The file ends inside the universal header"))
        }
        var overflow: [UInt8] = []
        overflow.be32(0xCAFE_BABF); overflow.be32(1)
        overflow.be32(0x0100_000C); overflow.be32(0); overflow.be64(.max - 4); overflow.be64(100)
        overflow.be32(14); overflow.be32(0)
        XCTAssertThrowsError(try MachOInfo.read(at: try write("fat-overflow", Data(overflow))))
    }

    /// Random damage to a real binary's header and load commands must
    /// throw or parse, never crash.
    func testRandomDamageNeverCrashes() throws {
        let url = try compile("tool", mainSource, ["-arch", "arm64", "-arch", "x86_64"])
        let original = [UInt8](try Data(contentsOf: url))
        var state: UInt64 = 0x5EED
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: state >> 33)
        }
        for round in 0..<300 {
            var bytes = original
            for _ in 0..<(1 + next() % 8) {
                // Mostly the fat header and the start of each slice.
                let offset = next() % 2 == 0 ? next() % 64 : (0x4000 + next() % 2048) % bytes.count
                bytes[offset] = UInt8(truncatingIfNeeded: next())
            }
            let damaged = try write("damaged-\(round)", Data(bytes.prefix(next() % 3 == 0 ? next() % bytes.count : bytes.count)))
            _ = try? MachOInfo.read(at: damaged)
            _ = try? BinaryFile.inspect(damaged)
        }
    }

    // MARK: - Prefix-only architecture names

    func testArchitecturesFromAPrefixMatchTheFullReader() throws {
        let url = try compile("fat", mainSource, ["-arch", "arm64", "-arch", "x86_64"])
        let head = [UInt8](try Data(contentsOf: url).prefix(MachOHeader.prefixLength))
        XCTAssertEqual(MachOHeader.architectures(in: head), try MachOInfo.read(at: url).slices.map(\.architecture))
        XCTAssertEqual(MachOHeader.architectures(in: bigEndianBinary()), ["ppc"])
    }
}
