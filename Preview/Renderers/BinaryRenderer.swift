import AppKit
import SwiftUI
import SpyglassKit

/// Mach-O binaries, static libraries, ELF files and extensionless
/// executables. Binaries get the bundle card (General, Architectures,
/// Linked Libraries, Rpaths, Segments, Signing, Entitlements); an
/// executable that turns out to be a script goes to the code view.
@MainActor
struct BinaryRenderer: PreviewRenderer {

    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView {
        let preview = try await Task.detached(priority: .userInitiated) {
            try BinaryPreview.load(url)
        }.value
        switch preview {
        case .script(let language):
            return try await CodeRenderer().makeView(for: url, kind: .code(language: language), settings: settings)
        case .card(let card):
            let contents = card.contents.map { ArchiveTreeView(tree: $0, expandAll: true) }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return NSHostingView(rootView: BundleCardView(card: card, icon: icon, contents: contents))
        }
    }
}

/// What the renderer shows, worked out off the main thread.
enum BinaryPreview: Sendable {
    case card(BundleCard)
    case script(language: String?)

    static func load(_ url: URL) throws -> BinaryPreview {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) }
        switch try BinaryFile.inspect(url) {
        case .script(let language):
            return .script(language: language)
        case .machO(let info):
            return .card(BundleCard.machO(info, url: url, fileSize: size))
        case .staticLibrary(let library):
            return .card(BundleCard.staticLibrary(library, url: url, fileSize: size))
        case .elf(let header):
            return .card(BundleCard.elf(header, url: url, fileSize: size))
        }
    }
}

extension BundleCard {

    // MARK: - Mach-O

    /// A thin binary shows its one architecture's sections in the card; a
    /// universal one lists its slices, then shows one slice at a time.
    static func machO(_ info: MachOInfo, url: URL, fileSize: UInt64?) -> BundleCard {
        let slices = info.slices
        let first = slices[0]
        let kind = slices.allSatisfy({ $0.fileType == first.fileType }) ? first.fileType.displayName : "Mach-O file"
        let architectures = slices.map(\.architecture)
        var card = BundleCard(
            title: url.lastPathComponent,
            subtitle: (info.isUniversal ? "Universal \(kind.lowercased())" : kind)
                + " · " + architectures.joined(separator: ", "))

        if info.isUniversal {
            card.sections.append(Section(title: "General", rows: rows([
                ("Kind", kind),
                ("Architectures", architectures.joined(separator: ", ")),
                ("Size", fileSize.map(bytes)),
            ])))
            card.sections.append(Section(title: "Architectures", rows: slices.map { slice in
                let parts = [slice.fileType.displayName, minimumOS(slice), bytes(slice.size)]
                return Row(label: slice.architecture, value: parts.compactMap { $0 }.joined(separator: " · "))
            }))
        } else {
            card.sections.append(Section(title: "General", rows: rows([
                ("Kind", kind),
                ("Architecture", first.architecture),
            ]) + sliceRows(first) + rows([("Size", fileSize.map(bytes))])))
            card.sections += listSections(first)
        }

        // Objects and debug-symbol files are never signed.
        if slices.contains(where: { $0.fileType != .object && $0.fileType != .dsym }) {
            if !slices.contains(where: \.hasCodeSignature) {
                card.sections.append(Section(title: "Signing", rows: [Row(label: "Signature", value: "Not signed")]))
            } else if let status = CodeSignature.read(at: url) {
                card.sections.append(signingSection(status))
                if case .signed(let signature) = status, !signature.entitlements.isEmpty {
                    card.sections.append(entitlements(signature.entitlements))
                }
            }
        }

        if info.isUniversal {
            card.variants = slices.map { slice in
                var details = sliceRows(slice)
                details.append(Row(label: "Slice", value: "\(bytes(slice.size)) at offset \(slice.offset.formatted())"))
                return Variant(title: slice.architecture,
                               sections: [Section(title: "Details", rows: details)] + listSections(slice))
            }
            card.variantLabel = "Architecture"
            // Open on the slice this Mac runs, whose signature Signing shows.
            #if arch(arm64)
            let native = "arm64"
            #else
            let native = "x86_64"
            #endif
            card.selectedVariant = slices.firstIndex { $0.architecture.hasPrefix(native) } ?? 0
        }
        return card
    }

    /// Platform, versions and flags of one architecture.
    private static func sliceRows(_ slice: MachOSlice) -> [Row] {
        rows([
            ("Minimum OS", minimumOS(slice)),
            ("SDK", list(slice.buildVersions.compactMap { version in version.sdk.map { "\(version.platform) \($0)" } },
                         separator: ", ")),
            ("UUID", slice.uuid?.uuidString),
            ("Install name", slice.identity?.path),
            ("Current version", slice.identity?.currentVersion),
            ("Compatibility version", slice.identity?.compatibilityVersion),
            ("Entry point", slice.hasMain ? "LC_MAIN" : nil),
            ("Flags", list(slice.notableFlags, separator: ", ")),
            ("Encryption", slice.isEncrypted.map { $0 ? "Encrypted" : "Not encrypted" }),
        ])
    }

    private static func minimumOS(_ slice: MachOSlice) -> String? {
        list(slice.buildVersions.map { "\($0.platform) \($0.minimumOS)" }, separator: ", ")
    }

    /// Linked libraries, rpaths and segments: the slice's long lists.
    private static func listSections(_ slice: MachOSlice) -> [Section] {
        var sections: [Section] = []
        if !slice.libraries.isEmpty {
            sections.append(Section(
                title: "Linked Libraries (\(slice.libraries.count.formatted()))",
                rows: slice.libraries.map { library in
                    var notes: [String] = []
                    switch library.kind {
                    case .normal: break
                    case .weak: notes.append("weak")
                    case .reexport: notes.append("re-exported")
                    case .lazy: notes.append("lazy")
                    case .upward: notes.append("upward")
                    }
                    if library.currentVersion != "0.0.0" { notes.append(library.currentVersion) }
                    return Row(label: library.path, value: notes.joined(separator: " · "))
                },
                style: .properties,
                startsCollapsed: slice.libraries.count > 12))
        }
        if !slice.rpaths.isEmpty {
            sections.append(Section(title: "Rpaths (\(slice.rpaths.count.formatted()))",
                                    rows: slice.rpaths.map { Row(label: $0, value: "") },
                                    style: .properties))
        }
        if slice.segments.count == 1, slice.segments[0].name.isEmpty {
            // Object files keep every section in one unnamed segment, so
            // the sections are what's worth listing.
            let parts = slice.segments[0].sections
            if !parts.isEmpty {
                sections.append(Section(title: "Sections (\(parts.count.formatted()))",
                                        rows: parts.map { Row(label: "\($0.segment),\($0.name)", value: bytes($0.size)) },
                                        style: .properties,
                                        startsCollapsed: parts.count > 12))
            }
        } else if !slice.segments.isEmpty {
            sections.append(Section(
                title: "Segments (\(slice.segments.count.formatted()))",
                rows: slice.segments.map { segment in
                    let file = bytes(segment.fileSize)
                    let memory = bytes(segment.vmSize)
                    let value = file == memory ? file : "\(file) in file · \(memory) in memory"
                    return Row(label: segment.name.isEmpty ? "(unnamed)" : segment.name, value: value)
                },
                style: .properties))
        }
        return sections
    }

    // MARK: - Static libraries

    static func staticLibrary(_ library: StaticLibrary, url: URL, fileSize: UInt64?) -> BundleCard {
        let kind = library.isUniversal ? "Universal static library" : "Static library"
        var subtitle = kind
        if !library.architectures.isEmpty { subtitle += " · " + library.architectures.joined(separator: ", ") }
        var card = BundleCard(title: url.lastPathComponent, subtitle: subtitle)
        let objects = library.members.filter { $0.architecture != nil }.count
        var members = objects == library.members.count
            ? "\(objects.formatted()) object \(objects == 1 ? "file" : "files")"
            : "\(library.members.count.formatted()) (\(objects.formatted()) object \(objects == 1 ? "file" : "files"))"
        if library.hitMemberLimit { members = "More than " + members }
        card.sections.append(Section(title: "General", rows: rows([
            ("Kind", kind),
            (library.architectures.count == 1 ? "Architecture" : "Architectures",
             list(library.architectures, separator: ", ")),
            ("Members", members),
            ("Symbol index", library.hasSymbolIndex ? "Yes" : "None"),
            ("Size", fileSize.map(bytes)),
        ])))

        // Members of a universal library repeat once per architecture, so
        // they're grouped into a folder per architecture.
        let grouped = Set(library.members.compactMap(\.architecture)).count > 1
        card.contents = ArchiveTree(entries: library.members.map { member in
            ArchiveEntry(path: grouped ? "\(member.architecture ?? "Other")/\(member.name)" : member.name,
                         kind: .file, size: member.size, modified: member.modified)
        })
        card.contentsTitle = "Members (\(library.members.count.formatted()))"
        if library.hitMemberLimit {
            card.contentsNote = "Showing the first \(library.members.count.formatted()) members"
        }
        return card
    }

    // MARK: - ELF

    static func elf(_ header: ELFHeader, url: URL, fileSize: UInt64?) -> BundleCard {
        var card = BundleCard(title: url.lastPathComponent,
                              subtitle: "ELF \(header.fileType.displayName.lowercased()) · \(header.machineName)")
        card.sections.append(Section(title: "General", rows: rows([
            ("Format", "ELF, \(header.is64Bit ? 64 : 32)-bit"),
            ("Type", header.fileType.displayName),
            ("Machine", header.machineName),
            ("Byte order", header.isBigEndian ? "Big-endian" : "Little-endian"),
            ("OS ABI", header.osABIName),
            ("Size", fileSize.map(bytes)),
        ])))
        return card
    }
}
