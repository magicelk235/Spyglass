import Foundation
import Security

/// One key/value line of a property list shown as text (entitlements).
public struct PropertyRow: Equatable, Sendable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    /// Sorted rows for a dictionary; nested values become indented text.
    static func rows(_ dictionary: [String: Any]) -> [PropertyRow] {
        dictionary.keys.sorted().map { PropertyRow(key: $0, value: describe(dictionary[$0] as Any)) }
    }

    /// Nesting past `depth` levels shows as "…": entitlements are shallow,
    /// and a hostile plist mustn't recurse the thread's stack away.
    static func describe(_ value: Any, depth: Int = 0) -> String {
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let date as Date:
            return date.ISO8601Format()
        case let data as Data:
            return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) + " of data"
        case let array as [Any]:
            guard depth < 16 else { return "…" }
            return array.isEmpty ? "(empty)" : array.map { describe($0, depth: depth + 1) }.joined(separator: "\n")
        case let dictionary as [String: Any]:
            guard depth < 16 else { return "…" }
            guard !dictionary.isEmpty else { return "(empty)" }
            return dictionary.keys.sorted().map { key in
                let value = describe(dictionary[key] as Any, depth: depth + 1)
                    .replacingOccurrences(of: "\n", with: "\n    ")
                return "\(key): \(value)"
            }.joined(separator: "\n")
        default:
            return String(describing: value)
        }
    }
}

/// What the Security framework reports about a bundle's or binary's code
/// signature.
public struct CodeSignature: Equatable, Sendable {
    public var identifier: String?
    public var teamIdentifier: String?
    /// Signing certificate first, root last.
    public var authorities: [String]
    public var isAdHoc: Bool
    /// The ad hoc signature the linker gives every arm64 binary it writes.
    public var isLinkerSigned = false
    public var isHardenedRuntime = false
    /// The secure timestamp when there is one, else the time the signer claims.
    public var signedAt: Date?
    public var entitlements: [PropertyRow]

    public enum Status: Equatable, Sendable {
        case unsigned
        case signed(CodeSignature)
    }

    /// nil when the code can't be examined at all. For a universal binary
    /// this is the signature of the slice this Mac would run.
    public static func read(at url: URL) -> Status? {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        if created == errSecCSUnsigned { return .unsigned }
        guard created == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        let copied = SecCodeCopySigningInformation(staticCode, flags, &info)
        if copied == errSecCSUnsigned { return .unsigned }
        guard copied == errSecSuccess, let values = info as? [String: Any] else { return nil }
        guard let identifier = values[kSecCodeInfoIdentifier as String] as? String else { return .unsigned }

        let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let signatureFlags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        return .signed(CodeSignature(
            identifier: identifier,
            teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String,
            authorities: certificates.compactMap { SecCertificateCopySubjectSummary($0) as String? },
            isAdHoc: signatureFlags & SecCodeSignatureFlags.adhoc.rawValue != 0,
            isLinkerSigned: signatureFlags & SecCodeSignatureFlags.linkerSigned.rawValue != 0,
            isHardenedRuntime: signatureFlags & SecCodeSignatureFlags.runtime.rawValue != 0,
            signedAt: values[kSecCodeInfoTimestamp as String] as? Date ?? values[kSecCodeInfoTime as String] as? Date,
            entitlements: PropertyRow.rows(entitlements)))
    }
}

/// An `embedded.mobileprovision`: a CMS-signed XML plist.
public struct ProvisioningProfile: Equatable, Sendable {
    public enum Distribution: String, Sendable {
        case development = "Development"
        case adHoc = "Ad Hoc"
        case enterprise = "Enterprise"
        case appStore = "App Store"
    }

    public var name: String?
    public var appIDName: String?
    public var teamName: String?
    public var teamIdentifiers: [String]
    public var created: Date?
    public var expires: Date?
    /// Devices listed in the profile; nil when it lists none.
    public var deviceCount: Int?
    public var distribution: Distribution
    public var platforms: [String]
    public var entitlements: [PropertyRow]

    public func isExpired(at now: Date = Date()) -> Bool {
        expires.map { $0 <= now } ?? false
    }

    public static func decode(_ data: Data) throws -> ProvisioningProfile {
        guard let plist = (try? PropertyListSerialization.propertyList(from: content(of: data), format: nil))
            as? [String: Any] else {
            throw ArchiveError.corrupt("The provisioning profile isn't readable")
        }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let devices = plist["ProvisionedDevices"] as? [Any]
        let distribution: Distribution
        if plist["ProvisionsAllDevices"] as? Bool == true {
            distribution = .enterprise
        } else if devices != nil {
            distribution = entitlements["get-task-allow"] as? Bool == true ? .development : .adHoc
        } else {
            distribution = .appStore
        }
        return ProvisioningProfile(
            name: plist["Name"] as? String,
            appIDName: plist["AppIDName"] as? String,
            teamName: plist["TeamName"] as? String,
            teamIdentifiers: plist["TeamIdentifier"] as? [String] ?? [],
            created: plist["CreationDate"] as? Date,
            expires: plist["ExpirationDate"] as? Date,
            deviceCount: devices?.count,
            distribution: distribution,
            platforms: plist["Platform"] as? [String] ?? [],
            entitlements: PropertyRow.rows(entitlements))
    }

    /// The signed content. A profile embeds its plist verbatim, so when the
    /// CMS wrapper won't decode the plist can still be cut out of it.
    private static func content(of data: Data) throws -> Data {
        guard !data.isEmpty else { throw ArchiveError.truncated("The provisioning profile is empty") }
        var decoder: CMSDecoder?
        if CMSDecoderCreate(&decoder) == errSecSuccess, let decoder {
            let updated = data.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
            var content: CFData?
            if updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
               CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content {
                return content as Data
            }
        }
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex) else {
            throw ArchiveError.corrupt("The provisioning profile isn't readable")
        }
        return data[start.lowerBound..<end.upperBound]
    }
}

/// What an `.app` bundle or `.ipa` says about itself. Every field is
/// optional: rows that can't be read are left out, never guessed.
public struct BundleInfo: Sendable {
    public var name: String
    public var bundleIdentifier: String?
    public var version: String?
    public var build: String?
    /// "macOS" or "iOS", for the minimum-version row's label.
    public var platform: String
    public var minimumSystem: String?
    public var category: String?
    public var copyright: String?
    public var devices: [String]
    public var architectures: [String]
    /// nil when the signature couldn't be examined (always for `.ipa`).
    public var signing: CodeSignature.Status?
    public var profile: ProvisioningProfile?
    /// The largest app icon PNG inside an `.ipa`.
    public var iconData: Data?

    static let plistLimit = 4 << 20

    // MARK: - .app

    public static func readApp(at url: URL) throws -> BundleInfo {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ArchiveError.unrecognized("\(url.lastPathComponent) isn't an app bundle")
        }
        // macOS bundles keep everything under Contents/; iOS-style bundles
        // (simulator builds) keep it at the top.
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let macStyle = FileManager.default.fileExists(atPath: contents.path)
        let plistURL = (macStyle ? contents : url).appendingPathComponent("Info.plist")
        let plist = (try? Data(contentsOf: plistURL, options: .mappedIfSafe))
            .flatMap { $0.count <= plistLimit ? $0 : nil }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any] ?? [:]

        var info = BundleInfo(plist: plist, fallbackName: url.deletingPathExtension().lastPathComponent,
                              platform: macStyle ? "macOS" : "iOS")
        if let executable = plist["CFBundleExecutable"] as? String, !executable.contains("/") {
            let binary = macStyle
                ? contents.appendingPathComponent("MacOS").appendingPathComponent(executable)
                : url.appendingPathComponent(executable)
            if let handle = try? FileHandle(forReadingFrom: binary) {
                defer { try? handle.close() }
                if let head = try? handle.read(upToCount: MachOHeader.prefixLength) {
                    info.architectures = MachOHeader.architectures(in: [UInt8](head)) ?? []
                }
            }
        }
        info.signing = CodeSignature.read(at: url)
        return info
    }

    // MARK: - .framework

    public static func readFramework(at url: URL) throws -> FrameworkInfo {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ArchiveError.unrecognized("\(url.lastPathComponent) isn't a framework bundle")
        }
        // macOS frameworks keep each version under Versions/ with a Current
        // link; iOS-style (shallow) frameworks keep everything at the top.
        let versionsFolder = url.appendingPathComponent("Versions", isDirectory: true)
        let current = versionsFolder.appendingPathComponent("Current", isDirectory: true)
        let isDeep = manager.fileExists(atPath: current.path)
        let root = isDeep ? current : url
        let plist = [root.appendingPathComponent("Resources/Info.plist"),
                     url.appendingPathComponent("Resources/Info.plist"),
                     url.appendingPathComponent("Info.plist")]
            .lazy
            .compactMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            .first { $0.count <= plistLimit }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any] ?? [:]

        let fallbackName = url.deletingPathExtension().lastPathComponent
        let platform = (plist["CFBundleSupportedPlatforms"] as? [String])?.first.flatMap { platformNames[$0] }
            ?? (isDeep ? "macOS" : "iOS")
        var bundle = BundleInfo(plist: plist, fallbackName: fallbackName, platform: platform)

        var versions: [String] = []
        var currentVersion: String?
        if isDeep {
            let names = (try? manager.contentsOfDirectory(atPath: versionsFolder.path)) ?? []
            versions = names.filter { $0 != "Current" && !$0.hasPrefix(".") }.sorted()
            currentVersion = (try? manager.destinationOfSymbolicLink(atPath: current.path))
                .map { ($0 as NSString).lastPathComponent }
        }
        let nested = (try? manager.contentsOfDirectory(atPath: root.appendingPathComponent("Frameworks").path)) ?? []
        let frameworks = nested.filter { $0.hasSuffix(".framework") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()

        let executable = (plist["CFBundleExecutable"] as? String).flatMap { $0.contains("/") || $0.isEmpty ? nil : $0 }
            ?? fallbackName
        let binaryURL = root.appendingPathComponent(executable)
        let binary: FrameworkInfo.Binary
        if manager.fileExists(atPath: binaryURL.path) {
            do {
                let info = try MachOInfo.read(at: binaryURL)
                binary = .machO(info)
                bundle.architectures = info.slices.map(\.architecture)
            } catch {
                binary = .unreadable(String(describing: error))
            }
        } else {
            binary = .missing(name: executable)
        }
        bundle.signing = CodeSignature.read(at: url)
        return FrameworkInfo(bundle: bundle, versions: versions, currentVersion: currentVersion,
                             frameworks: frameworks, binary: binary)
    }

    /// `CFBundleSupportedPlatforms` values.
    private static let platformNames = [
        "MacOSX": "macOS", "iPhoneOS": "iOS", "iPhoneSimulator": "iOS", "AppleTVOS": "tvOS",
        "AppleTVSimulator": "tvOS", "WatchOS": "watchOS", "WatchSimulator": "watchOS",
        "XROS": "visionOS", "XRSimulator": "visionOS", "DriverKit": "DriverKit",
    ]

    // MARK: - .ipa

    public static func readIPA(at url: URL) throws -> BundleInfo {
        // Big games ship more files than a listing shows; the app's
        // Info.plist can sit anywhere among them.
        let zip = try ZipReader(url: url, maxEntries: 500_000)
        // Payload/<Name>.app/Info.plist names the one app inside.
        guard let plistEntry = zip.entries.first(where: { entry in
            let parts = entry.path.split(separator: "/")
            return parts.count == 3 && parts[0].lowercased() == "payload"
                && parts[1].lowercased().hasSuffix(".app") && parts[2] == "Info.plist"
        }) else {
            throw ArchiveError.unsupported("No app inside the archive's Payload folder")
        }
        let appDirectory = String(plistEntry.path.dropLast("Info.plist".count))
        let plistData = try zip.contents(of: plistEntry, maxSize: plistLimit)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw ArchiveError.corrupt("The app's Info.plist isn't readable")
        }
        let appName = (String(appDirectory.dropLast()) as NSString).lastPathComponent
        var info = BundleInfo(plist: plist, fallbackName: (appName as NSString).deletingPathExtension, platform: "iOS")

        // The files directly inside the .app folder, by name.
        var members: [String: ZipEntry] = [:]
        for entry in zip.entries where entry.path.hasPrefix(appDirectory) && !entry.isDirectory {
            let name = String(entry.path.dropFirst(appDirectory.count))
            if !name.contains("/"), members[name] == nil { members[name] = entry }
        }
        if let entry = members["embedded.mobileprovision"], let data = try? zip.contents(of: entry, maxSize: 1 << 20) {
            info.profile = try? ProvisioningProfile.decode(data)
        }
        if let executable = plist["CFBundleExecutable"] as? String, let entry = members[executable],
           let head = try? zip.prefix(of: entry, length: MachOHeader.prefixLength) {
            info.architectures = MachOHeader.architectures(in: [UInt8](head)) ?? []
        }
        info.iconData = iconData(in: zip, members: members, plist: plist)
        return info
    }

    /// The biggest PNG the plist names as an icon, read only when small.
    private static func iconData(in zip: ZipReader, members: [String: ZipEntry], plist: [String: Any]) -> Data? {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let primary = (plist[key] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
            names += primary?["CFBundleIconFiles"] as? [String] ?? []
            if let name = primary?["CFBundleIconName"] as? String { names.append(name) }
        }
        names += plist["CFBundleIconFiles"] as? [String] ?? []
        if let name = plist["CFBundleIconFile"] as? String { names.append(name) }
        let prefixes = names.map { ($0.lowercased() as NSString).deletingPathExtension }.filter { !$0.isEmpty }
        guard !prefixes.isEmpty else { return nil }

        let candidates = members.filter { name, entry in
            let file = name.lowercased()
            return entry.uncompressedSize <= 1 << 20 && file.hasSuffix(".png") && prefixes.contains { file.hasPrefix($0) }
        }.values
        guard let best = candidates.max(by: { $0.uncompressedSize < $1.uncompressedSize }) else { return nil }
        return try? zip.contents(of: best, maxSize: 1 << 20)
    }

    // MARK: - Info.plist

    private init(plist: [String: Any], fallbackName: String, platform: String) {
        func text(_ key: String) -> String? {
            (plist[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        name = text("CFBundleDisplayName") ?? text("CFBundleName") ?? fallbackName
        bundleIdentifier = text("CFBundleIdentifier")
        version = text("CFBundleShortVersionString")
        build = text("CFBundleVersion")
        self.platform = platform
        minimumSystem = text("LSMinimumSystemVersion") ?? text("MinimumOSVersion")
        category = text("LSApplicationCategoryType").map(Self.categoryName)
        copyright = text("NSHumanReadableCopyright")
        devices = (plist["UIDeviceFamily"] as? [Int] ?? []).compactMap { Self.deviceFamilies[$0] }
        architectures = []
    }

    /// "public.app-category.developer-tools" reads as "Developer Tools".
    static func categoryName(_ identifier: String) -> String {
        let prefix = "public.app-category."
        guard identifier.hasPrefix(prefix) else { return identifier }
        return identifier.dropFirst(prefix.count)
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static let deviceFamilies = [1: "iPhone", 2: "iPad", 3: "Apple TV", 4: "Apple Watch", 7: "Apple Vision"]
}

/// What a `.framework` bundle holds: its Info.plist fields (as a
/// `BundleInfo`), the versions it carries, and its binary's headers.
public struct FrameworkInfo: Sendable {
    public enum Binary: Sendable {
        case machO(MachOInfo)
        /// The binary isn't on disk. macOS's own frameworks keep theirs in
        /// the dyld shared cache.
        case missing(name: String)
        case unreadable(String)
    }

    public var bundle: BundleInfo
    /// Folder names under `Versions/`, sorted; empty for a shallow framework.
    public var versions: [String]
    /// The version `Versions/Current` points to.
    public var currentVersion: String?
    /// Frameworks nested inside an umbrella framework, by name.
    public var frameworks: [String]
    public var binary: Binary
}
