import AppKit
import SwiftUI
import SpyglassKit

/// `.zip`, `.tar`, `.gz`, `.tgz`, `.bz2`, `.xz`, `.iso`: the archive's files
/// as a tree, under a one-line summary. Zip-based packages (`.jar`, `.whl`,
/// `.apk`...) add their manifest's fields above it. Lists only; nothing is
/// extracted.
@MainActor
struct ArchiveRenderer: PreviewRenderer {

    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView {
        guard case .archive(let format) = kind else { throw RenderError.unsupported("not an archive") }
        let package = format == .zip ? PackageType(filename: url.lastPathComponent) : nil
        let (listing, manifest, tree, archiveSize) = try await Task.detached(priority: .userInitiated) {
            var listing: ArchiveListing
            var manifest: PackageManifest?
            if let package {
                (listing, manifest) = try ArchiveReader.listPackage(url, type: package)
            } else {
                listing = try ArchiveReader.list(url, format: format)
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { UInt64($0) }
            return (listing, manifest, ArchiveTree(entries: listing.entries), size)
        }.value

        let container = NSView()
        let summary = NSTextField(labelWithString: Self.summary(of: tree, listing: listing, format: format,
                                                                archiveSize: archiveSize))
        summary.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.isSelectable = true
        let treeView = ArchiveTreeView(tree: tree)
        var views: [NSView] = [summary, treeView]
        var header: NSView?
        if let manifest {
            let hosting = NSHostingView(rootView: PackageSummaryView(manifest: manifest))
            hosting.sizingOptions = [.intrinsicContentSize]
            header = hosting
            views.insert(hosting, at: 0)
        }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var constraints = [
            summary.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            treeView.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 8),
            treeView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            treeView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            treeView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        if let header {
            constraints += [
                header.topAnchor.constraint(equalTo: container.topAnchor),
                header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                summary.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            ]
        } else {
            constraints.append(summary.topAnchor.constraint(equalTo: container.topAnchor, constant: 8))
        }
        NSLayoutConstraint.activate(constraints)
        return FallbackViews.withNote(container, note: Self.note(for: listing, format: format))
    }

    /// "12 files, 3 folders · 1.2 MB uncompressed · 340 KB compressed"
    static func summary(of tree: ArchiveTree, listing: ArchiveListing, format: ArchiveFormat,
                        archiveSize: UInt64?) -> String {
        var parts: [String] = []
        if let volume = listing.volumeName {
            parts.append("Volume “\(volume)”")
        }
        if listing.isSingleFile {
            parts.append("1 compressed file")
        } else if tree.fileCount == 0 && tree.folderCount == 0 {
            parts.append(format == .iso ? "Empty disc image" : "Empty archive")
        } else {
            var counts = [count(tree.fileCount, "file", "files")]
            if tree.folderCount > 0 { counts.append(count(tree.folderCount, "folder", "folders")) }
            parts.append(counts.joined(separator: ", "))
        }
        if format == .tar || format == .iso {
            parts.append(bytes(tree.totalSize) + " of files")
            if let archiveSize { parts.append(bytes(archiveSize) + " on disk") }
        } else {
            parts.append(bytes(tree.totalSize) + " uncompressed")
            if let archiveSize { parts.append(bytes(archiveSize) + " compressed") }
        }
        return parts.joined(separator: " · ")
    }

    /// The banner for a listing that isn't the whole archive.
    static func note(for listing: ArchiveListing, format: ArchiveFormat) -> String? {
        switch listing.incomplete {
        case nil:
            return nil
        case .entryLimit(let total?):
            return "Showing the first \(listing.entries.count.formatted()) of \(total.formatted()) entries"
        case .entryLimit(nil):
            return "Showing the first \(listing.entries.count.formatted()) entries"
        case .workLimit(let bytesRead):
            let amount = bytes(bytesRead)
            if format == .tar || format == .iso { return "Listing stopped after reading \(amount)" }
            if listing.isSingleFile {
                return format == .gzip
                    ? "Stopped decompressing after \(amount); the size shown comes from the gzip trailer"
                    : "Stopped decompressing after \(amount); the file is at least this large"
            }
            return "Listing stopped after decompressing \(amount)"
        case .damaged(let reason):
            return listing.isSingleFile
                ? "\(reason). The size shown is what decompressed before the damage."
                : "\(reason). Showing the entries before the damage."
        }
    }

    private static func count(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value.formatted()) \(value == 1 ? one : many)"
    }

    private static func bytes(_ value: UInt64) -> String {
        byteCountText(value)
    }
}

/// A package's manifest fields, above its file list.
struct PackageSummaryView: View {
    let manifest: PackageManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(manifest.kind).font(.headline)
                if let source = manifest.source {
                    Text(source)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if !manifest.fields.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(manifest.fields.enumerated()), id: \.offset) { _, field in
                        GridRow {
                            Text(field.label)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(field.value)
                                .lineLimit(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
