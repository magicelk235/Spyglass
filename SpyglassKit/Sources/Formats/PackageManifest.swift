import Foundation

/// A zip-based package format, named by its extension.
public enum PackageType: String, Sendable, CaseIterable {
    case jar, war, ear, apk, aab, whl, nupkg, vsix, xpi

    public init?(filename: String) {
        self.init(rawValue: (filename as NSString).pathExtension.lowercased())
    }
}

/// What a package's own metadata says, as rows for a summary above its
/// file list. Each format's manifest is one small member read from the
/// zip; an Android package is summarized from its file list instead.
public struct PackageManifest: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var label: String
        public var value: String
    }

    /// "Python wheel", "VS Code extension"...
    public var kind: String
    /// The member the fields come from; nil when they're counted from the
    /// file list.
    public var source: String?
    public var fields: [Field]

    /// Manifest members larger than this aren't read.
    static let memberLimit = 1 << 20

    /// nil when the package has no manifest this reader understands.
    public static func read(from zip: ZipReader, type: PackageType) -> PackageManifest? {
        switch type {
        case .jar: return java(zip, kind: "Java archive")
        case .war: return java(zip, kind: "Java web application")
        case .ear: return java(zip, kind: "Java enterprise application")
        case .whl: return wheel(zip)
        case .nupkg: return nuget(zip)
        case .vsix: return vsCode(zip) ?? visualStudio(zip)
        case .xpi: return firefox(zip)
        case .apk: return android(zip, kind: "Android app", isBundle: false)
        case .aab: return android(zip, kind: "Android App Bundle", isBundle: true)
        }
    }

    // MARK: - Java

    private static func java(_ zip: ZipReader, kind: String) -> PackageManifest? {
        guard let entry = zip.entries.first(where: {
            !$0.isDirectory && $0.path.caseInsensitiveCompare("META-INF/MANIFEST.MF") == .orderedSame
        }), let text = text(of: entry, in: zip) else { return nil }
        let attributes = jarManifestAttributes(text)
        return PackageManifest(kind: kind, source: entry.path, fields: fields([
            ("Main class", value(attributes, "Main-Class")),
            ("Title", value(attributes, "Implementation-Title")),
            ("Version", value(attributes, "Implementation-Version")),
            ("Module name", value(attributes, "Automatic-Module-Name")),
            ("Created by", value(attributes, "Created-By")),
        ]))
    }

    /// The main section of a JAR manifest: "Name: value" lines up to the
    /// first blank line, where a line starting with a space continues the
    /// value before it (lines wrap at 72 bytes).
    static func jarManifestAttributes(_ text: String) -> [(key: String, value: String)] {
        var attributes: [(key: String, value: String)] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.isEmpty {
                if attributes.isEmpty { continue }
                break
            }
            if line.hasPrefix(" ") {
                if !attributes.isEmpty { attributes[attributes.count - 1].value += line.dropFirst() }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            var value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
            attributes.append((String(line[..<colon]), String(value)))
        }
        return attributes
    }

    // MARK: - Python

    private static func wheel(_ zip: ZipReader) -> PackageManifest? {
        // The one top-level "<name>-<version>.dist-info" folder.
        func distInfo(_ name: String) -> ZipEntry? {
            zip.entries.first { entry in
                let parts = entry.path.split(separator: "/")
                return parts.count == 2 && parts[0].hasSuffix(".dist-info") && parts[1] == name
            }
        }
        let metadataEntry = distInfo("METADATA")
        let wheelEntry = distInfo("WHEEL")
        let metadata = metadataEntry.flatMap { text(of: $0, in: zip) }.map(headerFields) ?? []
        let wheel = wheelEntry.flatMap { text(of: $0, in: zip) }.map(headerFields) ?? []
        guard !metadata.isEmpty || !wheel.isEmpty else { return nil }

        let requirements = values(metadata, "Requires-Dist")
        let forExtras = requirements.filter { $0.range(of: #"extra\s*=="#, options: .regularExpression) != nil }.count
        var dependencies: String?
        if !requirements.isEmpty {
            dependencies = "\(requirements.count)" + (forExtras > 0 ? " (\(forExtras) only for extras)" : "")
        }
        return PackageManifest(kind: "Python wheel", source: (metadataEntry ?? wheelEntry)?.path, fields: fields([
            ("Name", value(metadata, "Name")),
            ("Version", value(metadata, "Version")),
            ("Summary", value(metadata, "Summary")),
            ("Requires Python", value(metadata, "Requires-Python")),
            ("Dependencies", dependencies),
            ("Tags", values(wheel, "Tag").joined(separator: ", ")),
        ]))
    }

    /// Email-style headers, as in a wheel's METADATA and WHEEL files:
    /// "Key: value" lines, indented lines continuing the previous value,
    /// ending at the first blank line (where the long description starts).
    static func headerFields(_ text: String) -> [(key: String, value: String)] {
        var headers: [(key: String, value: String)] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.allSatisfy(\.isWhitespace) { break }
            if line.first == " " || line.first == "\t" {
                if !headers.isEmpty {
                    headers[headers.count - 1].value += "\n" + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((String(line[..<colon]),
                            line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return headers
    }

    // MARK: - NuGet

    private static func nuget(_ zip: ZipReader) -> PackageManifest? {
        guard let entry = zip.entries.first(where: {
            !$0.isDirectory && !$0.path.contains("/") && $0.path.lowercased().hasSuffix(".nuspec")
        }), let data = try? zip.contents(of: entry, maxSize: memberLimit),
              let metadata = XARElement.parse(data)?.child("metadata") else { return nil }
        func text(_ name: String) -> String? { metadata.child(name)?.text }

        // Dependencies sit directly under <dependencies> or in one
        // <group> per target framework.
        let dependencyList = metadata.child("dependencies")
        let groups = dependencyList?.children("group") ?? []
        let dependencies = (dependencyList?.children("dependency") ?? []) + groups.flatMap { $0.children("dependency") }
        let ids = Set(dependencies.compactMap { $0.attributes["id"]?.lowercased() })
        let frameworks = groups.compactMap { $0.attributes["targetFramework"] }.filter { !$0.isEmpty }
        return PackageManifest(kind: "NuGet package", source: entry.path, fields: fields([
            ("ID", text("id")),
            ("Version", text("version")),
            ("Authors", text("authors")),
            ("Description", text("description")),
            ("Dependencies", ids.isEmpty ? nil : "\(ids.count)"),
            ("Frameworks", frameworks.joined(separator: ", ")),
        ]))
    }

    // MARK: - VS Code and Visual Studio

    private static func vsCode(_ zip: ZipReader) -> PackageManifest? {
        guard let entry = member("extension/package.json", in: zip), let json = jsonObject(entry, in: zip) else {
            return nil
        }
        // "%displayName%" placeholders come from package.nls.json.
        let strings = member("extension/package.nls.json", in: zip).flatMap { jsonObject($0, in: zip) } ?? [:]
        func string(_ key: String) -> String? {
            guard let value = json[key] as? String else { return nil }
            guard value.count > 2, value.hasPrefix("%"), value.hasSuffix("%") else { return value }
            let localized = strings[String(value.dropFirst().dropLast())]
            return localized as? String ?? (localized as? [String: Any])?["message"] as? String ?? value
        }
        let engines = (json["engines"] as? [String: Any] ?? [:])
            .sorted { $0.key < $1.key }
            .compactMap { name, range in (range as? String).map { "\(name) \($0)" } }
        return PackageManifest(kind: "VS Code extension", source: entry.path, fields: fields([
            ("Name", string("name")),
            ("Display name", string("displayName")),
            ("Version", string("version")),
            ("Publisher", string("publisher")),
            ("Engines", engines.joined(separator: ", ")),
            ("Description", string("description")),
        ]))
    }

    private static func visualStudio(_ zip: ZipReader) -> PackageManifest? {
        guard let entry = member("extension.vsixmanifest", in: zip),
              let data = try? zip.contents(of: entry, maxSize: memberLimit),
              let root = XARElement.parse(data) else { return nil }
        let metadata = root.child("Metadata")
        let identity = metadata?.child("Identity")
        let targets = (root.child("Installation")?.children("InstallationTarget") ?? []).compactMap { target in
            target.attributes["Id"].map { id in target.attributes["Version"].map { "\(id) \($0)" } ?? id }
        }
        return PackageManifest(kind: "Visual Studio extension", source: entry.path, fields: fields([
            ("ID", identity?.attributes["Id"]),
            ("Display name", metadata?.child("DisplayName")?.text),
            ("Version", identity?.attributes["Version"]),
            ("Publisher", identity?.attributes["Publisher"]),
            ("Targets", targets.joined(separator: "\n")),
            ("Description", metadata?.child("Description")?.text),
        ]))
    }

    // MARK: - Firefox

    private static func firefox(_ zip: ZipReader) -> PackageManifest? {
        guard let entry = member("manifest.json", in: zip), let json = jsonObject(entry, in: zip) else { return nil }
        // "__MSG_name__" strings come from the default locale's messages.
        var messages: [String: Any] = [:]
        if let locale = json["default_locale"] as? String, !locale.contains("/"),
           let file = member("_locales/\(locale)/messages.json", in: zip), let loaded = jsonObject(file, in: zip) {
            // Message names are case-insensitive.
            for (key, value) in loaded { messages[key.lowercased()] = value }
        }
        func string(_ key: String) -> String? {
            guard let value = json[key] as? String else { return nil }
            guard value.hasPrefix("__MSG_"), value.hasSuffix("__"), value.count > 8 else { return value }
            let name = value.dropFirst(6).dropLast(2).lowercased()
            return (messages[name] as? [String: Any])?["message"] as? String ?? value
        }
        let gecko = ((json["browser_specific_settings"] ?? json["applications"]) as? [String: Any])?["gecko"] as? [String: Any]
        let permissions = json["permissions"] as? [Any] ?? []
        let hosts = json["host_permissions"] as? [Any] ?? []
        return PackageManifest(kind: "Firefox add-on", source: entry.path, fields: fields([
            ("Name", string("name")),
            ("Version", string("version")),
            ("ID", gecko?["id"] as? String),
            ("Manifest version", (json["manifest_version"] as? NSNumber)?.stringValue),
            ("Permissions", permissions.isEmpty ? nil : "\(permissions.count)"),
            ("Host permissions", hosts.isEmpty ? nil : "\(hosts.count)"),
            ("Description", string("description")),
        ]))
    }

    // MARK: - Android

    /// The binary AndroidManifest.xml isn't decoded; the file list still
    /// says how much code, which native ABIs and which signatures there are.
    private static func android(_ zip: ZipReader, kind: String, isBundle: Bool) -> PackageManifest {
        var dexFiles = 0
        var libraries: [String: Int] = [:]
        var signatureFiles: [String] = []
        for entry in zip.entries where !entry.isDirectory {
            let lower = entry.path.lowercased()
            let parts = entry.path.split(separator: "/")
            // An APK keeps classes*.dex at the top and lib/<abi>/x.so; a
            // bundle has <module>/dex/ and <module>/lib/<abi>/ per module.
            let isDex = isBundle ? parts.count == 3 && parts[1] == "dex" : parts.count == 1
            if isDex, lower.hasSuffix(".dex") { dexFiles += 1 }
            let lib = isBundle ? 1 : 0
            if lower.hasSuffix(".so"), parts.count == lib + 3, parts[lib] == "lib" {
                libraries[String(parts[lib + 1]), default: 0] += 1
            }
            if parts.count == 2, parts[0] == "META-INF",
               [".rsa", ".ec", ".dsa"].contains(where: { lower.hasSuffix($0) }) {
                signatureFiles.append(String(parts[1]))
            }
        }
        var schemes = signatureFiles.isEmpty ? [] : ["v1 (\(signatureFiles.joined(separator: ", ")))"]
        schemes += apkSignatureSchemes(zip)
        let abis = libraries.keys.sorted().map { abi in
            let count = libraries[abi] ?? 0
            return "\(abi) (\(count) \(count == 1 ? "library" : "libraries"))"
        }
        return PackageManifest(kind: kind, source: nil, fields: fields([
            ("Code", dexFiles == 0 ? "No dex files" : dexFiles == 1 ? "1 dex file" : "\(dexFiles) dex files"),
            ("Native code", abis.isEmpty ? "None" : abis.joined(separator: "\n")),
            ("Signatures", schemes.isEmpty ? "None found" : schemes.joined(separator: ", ")),
        ]))
    }

    /// The APK Signature Scheme versions whose blocks sit in the APK
    /// signing block, which ends with "APK Sig Block 42" right before the
    /// central directory.
    static func apkSignatureSchemes(_ zip: ZipReader) -> [String] {
        let end = zip.directoryStart
        guard end >= 32, let tail = try? zip.rawBytes(at: end - 24, count: 24), tail.count == 24,
              Array(tail[8...]) == Array("APK Sig Block 42".utf8) else { return [] }
        let size = tail.withUnsafeBytes { buffer in
            var cursor = ByteCursor(buffer)
            return (try? cursor.u64le()) ?? 0
        }
        // The size counts everything after the leading size field.
        guard size >= 24, size <= 16 << 20, size + 8 <= end,
              let block = try? zip.rawBytes(at: end - size - 8, count: Int(size + 8)),
              block.count == Int(size + 8) else { return [] }
        var ids: Set<UInt32> = []
        block.withUnsafeBytes { buffer in
            var cursor = ByteCursor(UnsafeRawBufferPointer(rebasing: buffer[8..<(buffer.count - 24)]))
            while cursor.remaining >= 12 {
                guard let length = try? cursor.u64le(), length >= 4, length - 4 <= UInt64(cursor.remaining - 4),
                      let id = try? cursor.u32le(), (try? cursor.skip(Int(length - 4))) != nil else { break }
                ids.insert(id)
            }
        }
        let known: [(UInt32, String)] = [(0x7109_871A, "v2"), (0xF053_68C0, "v3"), (0x1B93_AD61, "v3.1")]
        return known.compactMap { ids.contains($0.0) ? $0.1 : nil }
    }

    // MARK: - Helpers

    private static func member(_ path: String, in zip: ZipReader) -> ZipEntry? {
        zip.entries.first { !$0.isDirectory && $0.path == path }
    }

    private static func text(of entry: ZipEntry, in zip: ZipReader) -> String? {
        guard let data = try? zip.contents(of: entry, maxSize: memberLimit) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func jsonObject(_ entry: ZipEntry, in zip: ZipReader) -> [String: Any]? {
        guard let data = try? zip.contents(of: entry, maxSize: memberLimit) else { return nil }
        // Browser extension manifests may carry comments.
        return (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any]
    }

    /// The first value for `key`, matched case-insensitively.
    private static func value(_ pairs: [(key: String, value: String)], _ key: String) -> String? {
        pairs.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    private static func values(_ pairs: [(key: String, value: String)], _ key: String) -> [String] {
        pairs.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }.map(\.value)
    }

    /// Rows for the values that are present, trimmed.
    private static func fields(_ pairs: [(String, String?)]) -> [Field] {
        pairs.compactMap { label, value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return Field(label: label, value: value)
        }
    }
}

extension ArchiveReader {
    /// Lists a zip-based package and reads its manifest through the same
    /// central directory. A file whose bytes say it's another kind of
    /// archive lists as that, without a manifest.
    public static func listPackage(_ url: URL, type: PackageType,
                                   limits: ArchiveLimits = .standard) throws -> (listing: ArchiveListing, manifest: PackageManifest?) {
        let head = try FileBytes(url: url).read(at: 0, count: 512)
        if let other = sniff(head), other != .zip {
            return (try list(url, format: other, limits: limits), nil)
        }
        let zip = try ZipReader(url: url, maxEntries: limits.maxEntries)
        return (zip.listing, PackageManifest.read(from: zip, type: type))
    }
}
