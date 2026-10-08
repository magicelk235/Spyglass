import Foundation
import Security

/// What a flat installer package (`.pkg`, a xar archive) says about itself,
/// read from its table of contents and its `Distribution` / `PackageInfo`
/// files. Nothing is installed or expanded beyond those small files.
public struct PackageInfo: Sendable {
    public struct Component: Equatable, Sendable {
        public var identifier: String
        public var version: String?
        /// Bytes installed, from `installKBytes`.
        public var installedSize: UInt64?
    }

    public var title: String?
    public var identifier: String?
    public var version: String?
    public var installLocation: String?
    public var minimumSystem: String?
    public var architectures: [String]
    public var components: [Component]
    /// Bytes installed, from `installKBytes`.
    public var installedSize: UInt64?
    public var payloadFileCount: Int?
    /// Bytes the `Payload` members take inside the package.
    public var payloadArchivedSize: UInt64?
    public var created: Date?
    /// Certificate names from the table of contents' signature, signer first.
    public var signers: [String]
    public var files: ArchiveListing

    static let tocLimit = 16 << 20
    static let memberLimit = 4 << 20

    public static func read(at url: URL, maxEntries: Int = ArchiveLimits.standard.maxEntries) throws -> PackageInfo {
        let file = try FileBytes(url: url)
        let header = try file.readExactly(at: 0, count: 28, "xar header")
        let (headerSize, tocCompressed, tocLength) = try header.withUnsafeBytes { buffer in
            var cursor = ByteCursor(buffer)
            guard try cursor.u32be() == 0x7861_7221 else {     // "xar!"
                throw ArchiveError.unrecognized("Not a flat installer package")
            }
            let size = UInt64(try cursor.u16be())
            _ = try cursor.u16be()                            // version
            return (size, try cursor.u64be(), try cursor.u64be())
        }
        guard headerSize >= 28, tocCompressed <= UInt64(tocLimit), tocLength <= UInt64(tocLimit) else {
            throw ArchiveError.tooLarge("The package's table of contents is too large")
        }
        let compressed = try file.readExactly(at: headerSize, count: Int(tocCompressed), "table of contents")
        let tocData = try decodeAll(compressed, with: try Inflater(.zlib), limit: tocLimit)
        guard let toc = XMLNode.parse(Data(tocData))?.child("toc") else {
            throw ArchiveError.corrupt("The package's table of contents isn't readable")
        }
        let heapStart = headerSize + tocCompressed

        var members: [(path: String, node: XMLNode)] = []
        var pending = toc.children("file").reversed().map { ("", $0) }
        while let (parent, node) = pending.popLast() {
            guard let name = node.child("name")?.text, !name.isEmpty else { continue }
            let path = parent.isEmpty ? name : parent + "/" + name
            members.append((path, node))
            pending += node.children("file").reversed().map { (path, $0) }
        }

        var info = PackageInfo(architectures: [], components: [], signers: [],
                               files: listing(of: members, maxEntries: maxEntries))
        info.created = toc.child("creation-time").flatMap { parseDate($0.text) }
        info.signers = signerNames(in: toc)
        let payloads = members.filter { ($0.path as NSString).lastPathComponent == "Payload" }
        if !payloads.isEmpty {
            info.payloadArchivedSize = saturatingSum(payloads.map { $0.node.child("data")?.child("length")?.number ?? 0 })
        }

        func memberData(_ path: String) -> Data? {
            guard let node = members.first(where: { $0.path == path })?.node else { return nil }
            return try? data(of: node, in: file, heapStart: heapStart)
        }
        if let distribution = memberData("Distribution").flatMap({ XMLNode.parse($0) }) {
            info.readDistribution(distribution)
        }
        // A component package has its own PackageInfo; a product archive
        // has one per component, which fill in what Distribution leaves out
        // (install location, file counts).
        if let packageInfo = memberData("PackageInfo").flatMap({ XMLNode.parse($0) }) {
            info.readPackageInfo(packageInfo, isOnlyComponent: true)
        } else {
            for (path, _) in members.filter({ $0.path.hasSuffix(".pkg/PackageInfo") }).prefix(32) {
                if let packageInfo = memberData(path).flatMap({ XMLNode.parse($0) }) {
                    info.readPackageInfo(packageInfo, isOnlyComponent: false)
                }
            }
        }
        return info
    }

    // MARK: - Table of contents

    private static func listing(of members: [(path: String, node: XMLNode)], maxEntries: Int) -> ArchiveListing {
        var entries: [ArchiveEntry] = []
        for (path, node) in members.prefix(maxEntries) {
            let kind: ArchiveEntry.Kind
            switch node.child("type")?.text {
            case "directory": kind = .directory
            case "symlink": kind = .symlink
            case "hardlink": kind = .hardlink
            case "file", nil: kind = .file
            default: kind = .other
            }
            let size = node.child("data")?.child("size")?.number ?? 0
            entries.append(ArchiveEntry(path: path, kind: kind, size: kind == .directory ? 0 : size,
                                        modified: node.child("mtime").flatMap { parseDate($0.text) },
                                        linkTarget: node.child("link")?.text))
        }
        let incomplete: ArchiveListing.Incomplete? = members.count > maxEntries
            ? .entryLimit(total: UInt64(members.count)) : nil
        return ArchiveListing(entries: entries, incomplete: incomplete)
    }

    /// The certificates xar stores beside its signature, as names.
    private static func signerNames(in toc: XMLNode) -> [String] {
        for signature in toc.children("signature") + toc.children("x-signature") {
            let names = (signature.child("KeyInfo")?.child("X509Data")?.children("X509Certificate") ?? [])
                .compactMap { Data(base64Encoded: $0.text, options: .ignoreUnknownCharacters) }
                .compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
                .compactMap { SecCertificateCopySubjectSummary($0) as String? }
            if !names.isEmpty { return names }
        }
        return []
    }

    /// One member's bytes from the heap, decoded. Only small members.
    private static func data(of node: XMLNode, in file: FileBytes, heapStart: UInt64) throws -> Data {
        guard let data = node.child("data"),
              let offset = data.child("offset")?.number,
              let length = data.child("length")?.number, length <= UInt64(memberLimit) else {
            throw ArchiveError.unsupported("Member isn't readable")
        }
        let (start, overflow) = heapStart.addingReportingOverflow(offset)
        guard !overflow else { throw ArchiveError.corrupt("Member offset is impossible") }
        let raw = try file.readExactly(at: start, count: Int(length), "package member")
        switch data.child("encoding")?.attributes["style"] ?? "application/octet-stream" {
        case "application/octet-stream":
            return Data(raw)
        case "application/x-gzip":
            // xar's "gzip" is a zlib stream; accept a real gzip header too.
            let inflater = try Inflater(raw.starts(with: [0x1F, 0x8B]) ? .gzip : .zlib)
            return Data(try decodeAll(raw, with: inflater, limit: memberLimit))
        case "application/x-bzip2":
            return Data(try decodeAll(raw, with: try Bunzipper(), limit: memberLimit))
        default:
            throw ArchiveError.unsupported("Member uses an unsupported encoding")
        }
    }

    // MARK: - Distribution and PackageInfo

    private mutating func readDistribution(_ root: XMLNode) {
        if let text = root.child("title")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            title = text
        }
        if let product = root.child("product") {
            identifier = product.attributes["id"]
            version = product.attributes["version"]
        }
        if let hosts = root.child("options")?.attributes["hostArchitectures"] {
            architectures = hosts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let osVersions = root.child("allowed-os-versions")
            ?? root.child("volume-check")?.child("allowed-os-versions")
        minimumSystem = osVersions?.children("os-version").compactMap { $0.attributes["min"] }.first

        // A component appears as several pkg-ref elements (in choices and
        // at the top level); merge them by id, in first-seen order.
        var order: [String] = []
        var byID: [String: Component] = [:]
        for ref in root.children("pkg-ref") {
            guard let id = ref.attributes["id"] else { continue }
            var component = byID[id] ?? Component(identifier: id)
            if order.contains(id) == false { order.append(id) }
            component.version = component.version ?? ref.attributes["version"]
            if let size = Self.bytes(kilobytes: ref.attributes["installKBytes"]) {
                component.installedSize = size
            }
            byID[id] = component
        }
        components = order.compactMap { byID[$0] }
        let sizes = components.compactMap(\.installedSize)
        if !sizes.isEmpty { installedSize = Self.saturatingSum(sizes) }
        if identifier == nil, components.count == 1 {
            identifier = components[0].identifier
            version = version ?? components[0].version
        }
    }

    private mutating func readPackageInfo(_ root: XMLNode, isOnlyComponent: Bool) {
        guard root.name == "pkg-info" else { return }
        installLocation = installLocation ?? root.attributes["install-location"]
        if isOnlyComponent {
            identifier = identifier ?? root.attributes["identifier"]
            version = version ?? root.attributes["version"]
        }
        guard let payload = root.child("payload") else { return }
        if let count = payload.attributes["numberOfFiles"].flatMap({ Int($0) }), count >= 0 {
            let (sum, overflow) = (payloadFileCount ?? 0).addingReportingOverflow(count)
            payloadFileCount = overflow ? .max : sum
        }
        // Distribution's pkg-refs already gave the installed size when present.
        if components.allSatisfy({ $0.installedSize == nil }),
           let size = Self.bytes(kilobytes: payload.attributes["installKBytes"]) {
            installedSize = Self.saturatingSum([installedSize ?? 0, size])
        }
    }

    /// `installKBytes` in bytes; nil when missing or past any real size.
    private static func bytes(kilobytes text: String?) -> UInt64? {
        guard let kilobytes = text.flatMap({ UInt64($0) }), kilobytes <= UInt64.max / 1024 else { return nil }
        return kilobytes * 1024
    }

    private static func saturatingSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // xar writes UTC, sometimes without the trailing Z, and the epoch
        // where a time was never recorded.
        guard let date = try? Date(trimmed.hasSuffix("Z") ? trimmed : trimmed + "Z", strategy: .iso8601),
              date.timeIntervalSince1970 != 0 else { return nil }
        return date
    }
}

/// A minimal XML element tree, enough for xar tables of contents and
/// installer scripts. Element count is capped so a hostile file can't
/// balloon memory.
final class XMLNode {
    let name: String
    let attributes: [String: String]
    fileprivate(set) var text = ""
    fileprivate(set) var elements: [XMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> XMLNode? { elements.first { $0.name == name } }
    func children(_ name: String) -> [XMLNode] { elements.filter { $0.name == name } }
    var number: UInt64? { UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)) }

    /// The document's root element; nil for malformed XML. Past
    /// `maxElements` elements or `maxDepth` levels parsing stops and the tree
    /// so far is kept; freeing nodes recurses, so depth must stay bounded.
    static func parse(_ data: Data, maxElements: Int = 500_000, maxDepth: Int = 64) -> XMLNode? {
        let builder = Builder(maxElements: maxElements, maxDepth: maxDepth)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse() || builder.hitLimit else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let maxElements: Int
        let maxDepth: Int
        var root: XMLNode?
        var stack: [XMLNode] = []
        var count = 0
        var hitLimit = false

        init(maxElements: Int, maxDepth: Int) {
            self.maxElements = maxElements
            self.maxDepth = maxDepth
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            count += 1
            guard count <= maxElements, stack.count < maxDepth else {
                hitLimit = true
                parser.abortParsing()
                return
            }
            let node = XMLNode(name: name, attributes: attributes)
            if let parent = stack.last { parent.elements.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let node = stack.last, node.text.utf8.count < 1 << 20 else { return }
            node.text += string
        }
    }
}
