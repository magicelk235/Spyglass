import CryptoKit
import XCTest
@testable import SpyglassKit

/// Bencode writer for building test torrents from readable values.
/// Dictionaries are written in the order given, sorted or not.
private indirect enum B {
    case int(Int64)
    case str(String)
    case raw(Data)
    case list([B])
    case dict([(String, B)])

    var encoded: Data {
        switch self {
        case .int(let value): return Data("i\(value)e".utf8)
        case .str(let text): return B.raw(Data(text.utf8)).encoded
        case .raw(let bytes): return Data("\(bytes.count):".utf8) + bytes
        case .list(let items): return Data("l".utf8) + items.reduce(Data()) { $0 + $1.encoded } + Data("e".utf8)
        case .dict(let pairs):
            return Data("d".utf8) + pairs.reduce(Data()) { $0 + B.str($1.0).encoded + $1.1.encoded } + Data("e".utf8)
        }
    }
}

private func hex<D: Digest>(_ digest: D) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

final class TorrentInfoTests: XCTestCase {

    private let pieces20 = B.raw(Data(repeating: 0x41, count: 20))

    private func singleFileInfo() -> B {
        .dict([
            ("length", .int(5)),
            ("name", .str("a.txt")),
            ("piece length", .int(16_384)),
            ("pieces", pieces20),
        ])
    }

    private func parse(_ torrent: B) throws -> TorrentInfo {
        try TorrentInfo.parse(torrent.encoded)
    }

    // MARK: - v1

    func testSingleFileTorrent() throws {
        let info = try parse(.dict([
            ("announce", .str("udp://tracker.example:1337/announce")),
            ("comment", .str("Hello")),
            ("created by", .str("mktorrent 1.1")),
            ("creation date", .int(1_700_000_000)),
            ("info", singleFileInfo()),
        ]))
        XCTAssertEqual(info.name, "a.txt")
        XCTAssertTrue(info.isSingleFile)
        XCTAssertEqual(info.files, [TorrentInfo.File(path: ["a.txt"], length: 5)])
        XCTAssertEqual(info.totalSize, 5)
        XCTAssertEqual(info.pieceLength, 16_384)
        XCTAssertEqual(info.pieceCount, 1)
        XCTAssertEqual(info.trackers, [TorrentInfo.Tracker(url: "udp://tracker.example:1337/announce", tier: 1)])
        XCTAssertEqual(info.comment, "Hello")
        XCTAssertEqual(info.createdBy, "mktorrent 1.1")
        XCTAssertEqual(info.creationDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertFalse(info.isPrivate)
        XCTAssertEqual(info.version, .v1)
        XCTAssertNil(info.infoHashV2)
    }

    func testInfoHashMatchesAKnownVector() throws {
        // shasum of the exact info dictionary bytes, computed outside Swift:
        // printf 'd6:lengthi5e4:name5:a.txt12:piece lengthi16384e6:pieces20:AAAAAAAAAAAAAAAAAAAAe' | shasum
        let info = try parse(.dict([("info", singleFileInfo())]))
        XCTAssertEqual(info.infoHashV1, "57dbb584ee2949d14ea359b3c3e66eba8ff6ac94")
    }

    func testInfoHashIsTakenOverTheExactBytesEvenWhenKeysAreUnsorted() throws {
        // Re-encoding would sort these keys and change the hash.
        let infoDict = B.dict([
            ("pieces", pieces20),
            ("name", .str("b.bin")),
            ("piece length", .int(16_384)),
            ("length", .int(9)),
            ("x-custom", .list([.int(1), .str("kept")])),
        ])
        let info = try parse(.dict([("info", infoDict), ("announce", .str("http://t/announce"))]))
        XCTAssertEqual(info.infoHashV1, hex(Insecure.SHA1.hash(data: infoDict.encoded)))
    }

    func testMultiFileTorrent() throws {
        let info = try parse(.dict([("info", .dict([
            ("files", .list([
                .dict([("length", .int(3)), ("path", .list([.str("Disc 1"), .str("01 Intro.flac")]))]),
                .dict([("length", .int(7)), ("path", .list([.str("Disc 1"), .str("02 Song.flac")]))]),
                .dict([("length", .int(11)), ("path", .list([.str("cover.jpg")]))]),
            ])),
            ("name", .str("Album")),
            ("piece length", .int(32_768)),
            ("pieces", .raw(Data(count: 40))),
        ]))]))
        XCTAssertEqual(info.name, "Album")
        XCTAssertFalse(info.isSingleFile)
        XCTAssertEqual(info.files, [
            TorrentInfo.File(path: ["Disc 1", "01 Intro.flac"], length: 3),
            TorrentInfo.File(path: ["Disc 1", "02 Song.flac"], length: 7),
            TorrentInfo.File(path: ["cover.jpg"], length: 11),
        ])
        XCTAssertEqual(info.totalSize, 21)
        XCTAssertEqual(info.pieceCount, 2)
    }

    func testPaddingFilesAreLeftOut() throws {
        let info = try parse(.dict([("info", .dict([
            ("files", .list([
                .dict([("length", .int(10)), ("path", .list([.str("a.bin")]))]),
                .dict([("attr", .str("p")), ("length", .int(16_374)), ("path", .list([.str(".pad"), .str("16374")]))]),
                .dict([("length", .int(4)), ("path", .list([.str("b.bin")]))]),
            ])),
            ("name", .str("Set")),
            ("piece length", .int(16_384)),
            ("pieces", .raw(Data(count: 40))),
        ]))]))
        XCTAssertEqual(info.files.map(\.path), [["a.bin"], ["b.bin"]])
        XCTAssertEqual(info.totalSize, 14)
    }

    func testUTF8VariantsOfNameAndPathWin() throws {
        let info = try parse(.dict([("info", .dict([
            ("files", .list([
                .dict([("length", .int(1)),
                       ("path", .list([.raw(Data([0xC3]))])),
                       ("path.utf-8", .list([.str("Café.txt")]))]),
            ])),
            ("name", .raw(Data([0xFF, 0xFE]))),
            ("name.utf-8", .str("Ünïcode")),
            ("piece length", .int(16_384)),
            ("pieces", pieces20),
        ]))]))
        XCTAssertEqual(info.name, "Ünïcode")
        XCTAssertEqual(info.files.first?.path, ["Café.txt"])
    }

    func testNonUTF8TextUsesTheDeclaredEncoding() throws {
        // "日本" in Shift JIS.
        let shiftJIS = Data([0x93, 0xFA, 0x96, 0x7B])
        let info = try parse(.dict([
            ("encoding", .str("Shift_JIS")),
            ("info", .dict([
                ("length", .int(1)), ("name", .raw(shiftJIS)),
                ("piece length", .int(16_384)), ("pieces", pieces20),
            ])),
        ]))
        XCTAssertEqual(info.name, "日本")
    }

    func testAnnounceListTiersAreKeptAndDeduplicated() throws {
        let info = try parse(.dict([
            ("announce", .str("udp://a/announce")),
            ("announce-list", .list([
                .list([.str("udp://a/announce"), .str("udp://b/announce")]),
                .list([.str("udp://b/announce"), .str(" http://c/announce ")]),
                .list([.str("")]),
                .int(5),
                .list([.str("udp://d/announce")]),
            ])),
            ("info", singleFileInfo()),
            ("url-list", .list([.str("https://mirror.example/a.txt")])),
        ]))
        // Empty and malformed tiers don't take a tier number.
        XCTAssertEqual(info.trackers, [
            TorrentInfo.Tracker(url: "udp://a/announce", tier: 1),
            TorrentInfo.Tracker(url: "udp://b/announce", tier: 1),
            TorrentInfo.Tracker(url: "http://c/announce", tier: 2),
            TorrentInfo.Tracker(url: "udp://d/announce", tier: 3),
        ])
        XCTAssertEqual(info.webSeeds, ["https://mirror.example/a.txt"])
    }

    func testAnnounceMissingFromTheListLeadsTheFirstTier() throws {
        let info = try parse(.dict([
            ("announce", .str("udp://main/announce")),
            ("announce-list", .list([.list([.str("udp://a/announce")]), .list([.str("udp://b/announce")])])),
            ("info", singleFileInfo()),
        ]))
        XCTAssertEqual(info.trackers.map(\.url), ["udp://main/announce", "udp://a/announce", "udp://b/announce"])
        XCTAssertEqual(info.trackers.map(\.tier), [1, 1, 2])
    }

    func testSingleWebSeedString() throws {
        let info = try parse(.dict([("info", singleFileInfo()), ("url-list", .str("https://m/a.txt"))]))
        XCTAssertEqual(info.webSeeds, ["https://m/a.txt"])
        XCTAssertEqual(info.trackers, [])
    }

    func testPrivateFlag() throws {
        let info = try parse(.dict([("info", .dict([
            ("length", .int(5)), ("name", .str("a.txt")), ("piece length", .int(16_384)),
            ("pieces", pieces20), ("private", .int(1)),
        ]))]))
        XCTAssertTrue(info.isPrivate)
    }

    // MARK: - v2

    private func fileTree() -> B {
        .dict([
            ("big.bin", .dict([("", .dict([("length", .int(40_000)), ("pieces root", .raw(Data(count: 32)))]))])),
            ("docs", .dict([
                ("readme.txt", .dict([("", .dict([("length", .int(5)), ("pieces root", .raw(Data(count: 32)))]))])),
            ])),
        ])
    }

    func testV2OnlyTorrentReadsTheFileTreeAndHashesWithSHA256() throws {
        let infoDict = B.dict([
            ("file tree", fileTree()),
            ("meta version", .int(2)),
            ("name", .str("pack")),
            ("piece length", .int(16_384)),
        ])
        let info = try parse(.dict([("info", infoDict), ("piece layers", .dict([]))]))
        XCTAssertEqual(info.version, .v2)
        XCTAssertEqual(info.files, [
            TorrentInfo.File(path: ["big.bin"], length: 40_000),
            TorrentInfo.File(path: ["docs", "readme.txt"], length: 5),
        ])
        XCTAssertEqual(info.totalSize, 40_005)
        // Three pieces for big.bin, one for readme.txt: v2 pieces never span files.
        XCTAssertEqual(info.pieceCount, 4)
        XCTAssertEqual(info.infoHashV2, hex(SHA256.hash(data: infoDict.encoded)))
        XCTAssertNil(info.infoHashV1)
    }

    func testHybridTorrentHasBothHashesAndUsesTheV1FileList() throws {
        let infoDict = B.dict([
            ("file tree", fileTree()),
            ("files", .list([
                .dict([("length", .int(40_000)), ("path", .list([.str("big.bin")]))]),
                .dict([("attr", .str("p")), ("length", .int(9_152)), ("path", .list([.str(".pad"), .str("9152")]))]),
                .dict([("length", .int(5)), ("path", .list([.str("docs"), .str("readme.txt")]))]),
            ])),
            ("meta version", .int(2)),
            ("name", .str("pack")),
            ("piece length", .int(16_384)),
            ("pieces", .raw(Data(count: 80))),
        ])
        let info = try parse(.dict([("info", infoDict)]))
        XCTAssertEqual(info.version, .hybrid)
        XCTAssertEqual(info.files.map(\.path), [["big.bin"], ["docs", "readme.txt"]])
        XCTAssertEqual(info.pieceCount, 4)
        XCTAssertEqual(info.infoHashV1, hex(Insecure.SHA1.hash(data: infoDict.encoded)))
        XCTAssertEqual(info.infoHashV2, hex(SHA256.hash(data: infoDict.encoded)))
    }

    // MARK: - Malformed

    private func assertRejects(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TorrentInfo.parse(data), file: file, line: line)
    }

    func testRejectsNonTorrents() {
        assertRejects(Data())
        assertRejects(B.list([.str("info")]).encoded)
        assertRejects(B.dict([("announce", .str("udp://a"))]).encoded)
        assertRejects(B.dict([("info", .str("not a dictionary"))]).encoded)
        assertRejects(Data("PK\u{03}\u{04} not bencode".utf8))
    }

    func testRejectsInfoWithoutFiles() {
        assertRejects(B.dict([("info", .dict([("name", .str("x")), ("piece length", .int(16_384))]))]).encoded)
    }

    func testRejectsBadFileEntries() {
        func torrent(_ file: B) -> Data {
            B.dict([("info", .dict([
                ("files", .list([file])), ("name", .str("x")),
                ("piece length", .int(16_384)), ("pieces", pieces20),
            ]))]).encoded
        }
        assertRejects(torrent(.dict([("length", .int(-1)), ("path", .list([.str("a")]))])))
        assertRejects(torrent(.dict([("length", .int(1)), ("path", .list([]))])))
        assertRejects(torrent(.dict([("length", .int(1))])))
        assertRejects(torrent(.str("a")))
    }

    func testRejectsNegativeSingleFileLength() {
        assertRejects(B.dict([("info", .dict([
            ("length", .int(-5)), ("name", .str("a")), ("piece length", .int(16_384)), ("pieces", pieces20),
        ]))]).encoded)
    }

    func testRejectsPiecesThatAreNotWholeHashes() {
        assertRejects(B.dict([("info", .dict([
            ("length", .int(5)), ("name", .str("a")), ("piece length", .int(16_384)),
            ("pieces", .raw(Data(count: 30))),
        ]))]).encoded)
    }

    func testRejectsTrailingJunkAndTruncation() {
        let good = B.dict([("info", singleFileInfo())]).encoded
        XCTAssertNoThrow(try TorrentInfo.parse(good))
        assertRejects(good + Data("x".utf8))
        for cut in [1, good.count / 2, good.count - 1] {
            assertRejects(good.prefix(cut))
        }
    }

    func testReadRefusesFilesOverTheSizeCap() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TorrentInfoTests-\(UUID().uuidString).torrent")
        defer { try? FileManager.default.removeItem(at: url) }
        try B.dict([("info", singleFileInfo())]).encoded.write(to: url)
        XCTAssertNoThrow(try TorrentInfo.read(at: url))
        XCTAssertThrowsError(try TorrentInfo.read(at: url, maxSize: 10)) { error in
            XCTAssertEqual(error as? BencodeError, .tooLarge)
        }
    }

    func testReadsTheSampleFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("samples/formats/sample.torrent")
        let info = try TorrentInfo.read(at: url)
        XCTAssertEqual(info.version, .v1)
        XCTAssertEqual(info.name, "Sample.dmg")
        XCTAssertEqual(info.totalSize, 16_852)
        XCTAssertEqual(info.pieceCount, 2)
        // Python's hashlib over the info dictionary it wrote.
        XCTAssertEqual(info.infoHashV1, "0ec732f394100897f5415db301cd94e74f576cb9")
        XCTAssertEqual(info.trackers.map(\.url), [
            "udp://tracker.example.org:6969/announce",
            "udp://tracker2.example.net:1337/announce",
            "https://tracker.example.com/announce",
        ])
        XCTAssertEqual(info.trackers.map(\.tier), [1, 1, 2])
    }
}
