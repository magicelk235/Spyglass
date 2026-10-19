import AppKit
import SwiftUI
import SpyglassKit

/// `.app`, `.ipa`, `.pkg`, `.dmg`, `.framework`: an info card with the
/// icon, then General, Signing, Provisioning, Entitlements and Contents
/// sections for whatever the file reveals. Rows that can't be read are
/// left out.
@MainActor
struct BundleRenderer: PreviewRenderer {

    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView {
        guard case .bundle(let format) = kind else { throw RenderError.unsupported("not a bundle") }
        let card = try await Task.detached(priority: .userInitiated) {
            try BundleCard.load(url, format: format)
        }.value
        let icon = card.iconData.flatMap { NSImage(data: $0) } ?? NSWorkspace.shared.icon(forFile: url.path)
        let contents = card.contents.map { ArchiveTreeView(tree: $0, expandAll: true) }
        return NSHostingView(rootView: BundleCardView(card: card, icon: icon, contents: contents))
    }
}

/// Everything the card shows, worked out off the main thread.
struct BundleCard: Sendable {
    struct Row: Sendable {
        var label: String
        var value: String
        var isWarning = false
    }

    struct Section: Sendable {
        enum Style: Sendable {
            /// Label and value columns.
            case table
            /// Key/value pairs from a property list, or a list of paths:
            /// monospaced, collapsible. A row with an empty value shows
            /// only its label.
            case properties
        }

        var title: String
        var rows: [Row]
        var style: Style = .table
        /// A long `.properties` list that opens folded.
        var startsCollapsed = false
    }

    /// Sections that differ per variant (a universal binary's
    /// architectures), shown one at a time under a picker.
    struct Variant: Sendable {
        var title: String
        var sections: [Section]
    }

    var title: String
    var subtitle: String
    var sections: [Section] = []
    var variants: [Variant] = []
    /// Names what the variants are ("Architecture").
    var variantLabel = ""
    /// The variant shown first.
    var selectedVariant = 0
    var contents: ArchiveTree?
    /// Heading over `contents`; "Contents (count)" when nil.
    var contentsTitle: String?
    var contentsNote: String?
    var iconData: Data?

    static func load(_ url: URL, format: BundleFormat) throws -> BundleCard {
        switch format {
        case .app: return app(try BundleInfo.readApp(at: url))
        case .ipa: return ipa(try BundleInfo.readIPA(at: url))
        case .pkg: return package(try PackageInfo.read(at: url), url: url)
        case .dmg: return diskImage(try DiskImageInfo.read(at: url), url: url)
        case .framework: return framework(try BundleInfo.readFramework(at: url), url: url)
        }
    }

    // MARK: - Apps

    private static func app(_ info: BundleInfo) -> BundleCard {
        var card = BundleCard(title: info.name, subtitle: subtitle("\(info.platform) app", info))
        card.sections.append(general(info))
        if let signing = info.signing { card.sections.append(signingSection(signing)) }
        if case .signed(let signature) = info.signing, !signature.entitlements.isEmpty {
            card.sections.append(entitlements(signature.entitlements))
        }
        return card
    }

    private static func ipa(_ info: BundleInfo) -> BundleCard {
        var card = BundleCard(title: info.name, subtitle: subtitle("iOS app archive", info))
        card.iconData = info.iconData
        card.sections.append(general(info))
        if let profile = info.profile {
            card.sections.append(provisioning(profile))
            if !profile.entitlements.isEmpty { card.sections.append(entitlements(profile.entitlements)) }
        }
        return card
    }

    private static func subtitle(_ kind: String, _ info: BundleInfo) -> String {
        var parts = [kind]
        switch (info.version, info.build) {
        case let (version?, build?) where version != build: parts.append("Version \(version) (\(build))")
        case let (version?, _): parts.append("Version \(version)")
        case let (nil, build?): parts.append("Build \(build)")
        case (nil, nil): break
        }
        return parts.joined(separator: " · ")
    }

    private static func general(_ info: BundleInfo) -> Section {
        Section(title: "General", rows: rows([
            ("Bundle ID", info.bundleIdentifier),
            ("Version", info.version),
            ("Build", info.build),
            ("Minimum \(info.platform)", info.minimumSystem),
            ("Devices", list(info.devices, separator: ", ")),
            ("Architectures", list(info.architectures, separator: ", ")),
            ("Category", info.category),
            ("Copyright", info.copyright),
        ]))
    }

    static func signingSection(_ status: CodeSignature.Status) -> Section {
        guard case .signed(let signature) = status else {
            return Section(title: "Signing", rows: [Row(label: "Signature", value: "Not signed")])
        }
        let signer: (String, String?)
        if signature.isAdHoc {
            signer = ("Signature", signature.isLinkerSigned ? "Ad hoc, added by the linker" : "Ad hoc, no certificate")
        } else {
            signer = ("Signed by", signature.authorities.first)
        }
        return Section(title: "Signing", rows: rows([
            signer,
            ("Team ID", signature.teamIdentifier),
            ("Identifier", signature.identifier),
            ("Certificate chain", signature.authorities.count > 1 ? signature.authorities.joined(separator: "\n") : nil),
            ("Hardened runtime", signature.isHardenedRuntime ? "Yes" : "No"),
            ("Signed", signature.signedAt.map(date)),
        ]))
    }

    static func entitlements(_ rows: [PropertyRow]) -> Section {
        Section(title: "Entitlements (\(rows.count))",
                rows: rows.map { Row(label: $0.key, value: $0.value) },
                style: .properties)
    }

    // MARK: - Frameworks

    private static func framework(_ framework: FrameworkInfo, url: URL) -> BundleCard {
        let info = framework.bundle
        let title = url.deletingPathExtension().lastPathComponent
        var card = BundleCard(title: title, subtitle: subtitle("\(info.platform) framework", info))
        let versions = framework.versions.map { $0 == framework.currentVersion ? "\($0) (current)" : $0 }
        card.sections.append(Section(title: "General", rows: rows([
            ("Name", info.name == title ? nil : info.name),
            ("Bundle ID", info.bundleIdentifier),
            ("Version", info.version),
            ("Build", info.build),
            ("Minimum \(info.platform)", info.minimumSystem),
            ("Versions", list(versions, separator: ", ")),
            ("Frameworks inside", list(framework.frameworks, separator: ", ")),
            ("Copyright", info.copyright),
        ])))

        switch framework.binary {
        case .machO(let binary):
            // Every slice carries the same install name and libraries.
            let slice = binary.slices[0]
            card.sections.append(Section(title: "Binary", rows: rows([
                ("Architectures", list(binary.slices.map(\.architecture), separator: ", ")),
                ("Install name", slice.identity?.path),
                ("Current version", slice.identity?.currentVersion),
                ("Compatibility version", slice.identity?.compatibilityVersion),
                ("Minimum OS", list(slice.buildVersions.map { "\($0.platform) \($0.minimumOS)" }, separator: ", ")),
                ("SDK", list(slice.buildVersions.compactMap { version in version.sdk.map { "\(version.platform) \($0)" } },
                             separator: ", ")),
                ("Linked libraries", "\(slice.libraries.count)"),
            ])))
        case .missing(let name):
            // macOS's own frameworks ship their code in the dyld shared cache.
            let row = url.path.hasPrefix("/System/")
                ? Row(label: "Location", value: "In the dyld shared cache, not on disk")
                : Row(label: "File", value: "\(name) is missing", isWarning: true)
            card.sections.append(Section(title: "Binary", rows: [row]))
        case .unreadable(let reason):
            card.sections.append(Section(title: "Binary", rows: [Row(label: "File", value: reason, isWarning: true)]))
        }

        if let signing = info.signing { card.sections.append(signingSection(signing)) }
        if case .signed(let signature) = info.signing, !signature.entitlements.isEmpty {
            card.sections.append(entitlements(signature.entitlements))
        }
        return card
    }

    private static func provisioning(_ profile: ProvisioningProfile) -> Section {
        var team = profile.teamName
        if !profile.teamIdentifiers.isEmpty {
            let ids = profile.teamIdentifiers.joined(separator: ", ")
            team = team.map { "\($0) (\(ids))" } ?? ids
        }
        let devices: String?
        if profile.distribution == .enterprise {
            devices = "All devices"
        } else {
            devices = profile.deviceCount.map { $0 == 1 ? "1 device" : "\($0.formatted()) devices" }
        }
        var result = Section(title: "Provisioning", rows: rows([
            ("Profile", profile.name),
            ("App ID name", profile.appIDName),
            ("Team", team),
            ("Distribution", profile.distribution.rawValue),
            ("Devices", devices),
            ("Platform", list(profile.platforms, separator: ", ")),
            ("Created", profile.created.map(date)),
        ]))
        if let expires = profile.expires {
            let expired = profile.isExpired()
            result.rows.append(Row(label: "Expires", value: date(expires) + (expired ? " (expired)" : ""),
                                   isWarning: expired))
        }
        return result
    }

    // MARK: - Installer packages

    private static func package(_ info: PackageInfo, url: URL) -> BundleCard {
        let isProduct = info.files.entries.contains { $0.path == "Distribution" }
        var subtitle = isProduct ? "Installer package" : "Component package"
        if let version = info.version { subtitle += " · Version \(version)" }
        var card = BundleCard(title: info.title ?? url.deletingPathExtension().lastPathComponent, subtitle: subtitle)

        var payload: [String] = []
        if let count = info.payloadFileCount { payload.append(count == 1 ? "1 file" : "\(count.formatted()) files") }
        if let archived = info.payloadArchivedSize { payload.append(bytes(archived) + " compressed") }
        card.sections.append(Section(title: "General", rows: rows([
            ("Identifier", info.identifier),
            ("Version", info.version),
            ("Install location", info.installLocation),
            ("Minimum macOS", info.minimumSystem),
            ("Architectures", list(info.architectures, separator: ", ")),
            ("Installed size", info.installedSize.map(bytes)),
            ("Payload", list(payload, separator: " · ")),
            ("Created", info.created.map(date)),
        ])))

        if info.components.count > 1 || (info.components.count == 1 && info.components[0].identifier != info.identifier) {
            card.sections.append(Section(title: "Components", rows: info.components.map { component in
                let detail = [component.version.map { "Version \($0)" }, component.installedSize.map(bytes)]
                    .compactMap { $0 }.joined(separator: " · ")
                return Row(label: component.identifier, value: detail.isEmpty ? "–" : detail)
            }, style: .properties))
        }

        if let signer = info.signers.first {
            card.sections.append(Section(title: "Signing", rows: rows([
                ("Signed by", signer),
                ("Certificate chain", info.signers.count > 1 ? info.signers.joined(separator: "\n") : nil),
            ])))
        } else {
            card.sections.append(Section(title: "Signing", rows: [Row(label: "Signature", value: "Not signed")]))
        }

        card.contents = ArchiveTree(entries: info.files.entries)
        if case .entryLimit(let total?) = info.files.incomplete {
            card.contentsNote = "Showing the first \(info.files.entries.count.formatted()) of \(total.formatted()) items"
        }
        return card
    }

    // MARK: - Disk images

    private static func diskImage(_ info: DiskImageInfo, url: URL) -> BundleCard {
        let description = info.format.flatMap(DiskImageInfo.describe(format:))
        var card = BundleCard(title: url.deletingPathExtension().lastPathComponent,
                              subtitle: description.map { "Disk image · \($0)" } ?? "Disk image")
        if info.isEncrypted {
            card.subtitle = "Encrypted disk image"
            card.sections.append(Section(title: "General", rows: [
                Row(label: "Encryption", value: "Encrypted; its contents can only be read once it's mounted"),
            ]))
            return card
        }
        card.sections.append(Section(title: "General", rows: rows([
            ("Format", info.format.map { format in description.map { "\(format) (\($0))" } ?? format }),
            ("Size when mounted", info.expandedSize.map(bytes)),
            ("Image data", info.compressedSize.map(bytes)),
            ("Partitions", list(info.partitions, separator: "\n")),
            ("UDIF version", info.version.map { "\($0)" }),
        ])))
        if let signing = info.signing {
            card.sections.append(signingSection(signing))
        } else {
            card.sections.append(Section(title: "Signing", rows: [
                Row(label: "Signature", value: info.isSigned ? "Signed" : "Not signed"),
            ]))
        }
        return card
    }

    // MARK: - Formatting

    static func rows(_ pairs: [(String, String?)]) -> [Row] {
        pairs.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return Row(label: label, value: value)
        }
    }

    static func list(_ items: [String], separator: String) -> String? {
        items.isEmpty ? nil : items.joined(separator: separator)
    }

    static func bytes(_ value: UInt64) -> String {
        byteCountText(value)
    }

    private static func date(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Views

struct BundleCardView: View {
    let card: BundleCard
    let icon: NSImage
    let contents: ArchiveTreeView?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.title)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                        Text(card.subtitle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                ForEach(Array(card.sections.enumerated()), id: \.offset) { _, section in
                    BundleSectionView(section: section)
                }
                if !card.variants.isEmpty {
                    VariantSectionsView(label: card.variantLabel, variants: card.variants, selection: card.selectedVariant)
                }
                if let contents, let tree = card.contents {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(card.contentsTitle ?? "Contents (\((tree.fileCount + tree.folderCount).formatted()))")
                            .font(.headline)
                        if let note = card.contentsNote {
                            Text(note).font(.callout).foregroundStyle(.secondary)
                        }
                        EmbeddedTree(view: contents)
                            .frame(height: min(contents.fittingHeight, 360))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One variant's sections at a time, chosen with a segmented picker.
private struct VariantSectionsView: View {
    let label: String
    let variants: [BundleCard.Variant]
    @State private var selection: Int

    init(label: String, variants: [BundleCard.Variant], selection: Int) {
        self.label = label
        self.variants = variants
        _selection = State(initialValue: variants.indices.contains(selection) ? selection : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text(label).font(.headline)
                Picker(label, selection: $selection) {
                    ForEach(variants.indices, id: \.self) { index in
                        Text(variants[index].title).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ForEach(Array(variants[min(selection, variants.count - 1)].sections.enumerated()), id: \.offset) { _, section in
                BundleSectionView(section: section)
            }
        }
    }
}

private struct BundleSectionView: View {
    let section: BundleCard.Section
    @State private var isExpanded: Bool

    init(section: BundleCard.Section) {
        self.section = section
        _isExpanded = State(initialValue: !section.startsCollapsed)
    }

    var body: some View {
        switch section.style {
        case .table:
            VStack(alignment: .leading, spacing: 6) {
                Text(section.title).font(.headline)
                GroupBox {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(row.label)
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 120, alignment: .trailing)
                                    .gridColumnAlignment(.trailing)
                                Text(row.value)
                                    .foregroundStyle(row.isWarning ? Color(nsColor: .systemRed) : Color.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(6)
                }
            }
        case .properties:
            DisclosureGroup(isExpanded: $isExpanded) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { Divider().padding(.vertical, 5) }
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(row.label)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if !row.value.isEmpty {
                                    Text(row.value)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)
                                }
                            }
                            .font(.system(.callout, design: .monospaced))
                        }
                    }
                    .padding(6)
                }
                .padding(.top, 6)
            } label: {
                Text(section.title).font(.headline)
            }
        }
    }
}

/// Hosts an existing tree view; built by the renderer so its height is
/// known before layout.
private struct EmbeddedTree: NSViewRepresentable {
    let view: ArchiveTreeView

    func makeNSView(context: Context) -> ArchiveTreeView { view }
    func updateNSView(_ nsView: ArchiveTreeView, context: Context) {}
}
