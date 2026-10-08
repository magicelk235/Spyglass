import AppKit
import SpyglassKit

/// `.zip`, `.tar`, `.gz`, `.tgz`, `.bz2`: the archive's files as a tree,
/// under a one-line summary. Lists only; nothing is extracted.
@MainActor
struct ArchiveRenderer: PreviewRenderer {

    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView {
        guard case .archive(let format) = kind else { throw RenderError.unsupported("not an archive") }
        let (listing, tree, archiveSize) = try await Task.detached(priority: .userInitiated) {
            let listing = try ArchiveReader.list(url, format: format)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { UInt64($0) }
            return (listing, ArchiveTree(entries: listing.entries), size)
        }.value

        let container = NSView()
        let summary = NSTextField(labelWithString: Self.summary(of: tree, listing: listing, format: format,
                                                                archiveSize: archiveSize))
        summary.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.isSelectable = true
        let treeView = ArchiveTreeView(tree: tree)
        for view in [summary, treeView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            summary.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            treeView.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 8),
            treeView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            treeView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            treeView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return FallbackViews.withNote(container, note: Self.note(for: listing, format: format))
    }

    /// "12 files, 3 folders · 1.2 MB uncompressed · 340 KB compressed"
    static func summary(of tree: ArchiveTree, listing: ArchiveListing, format: ArchiveFormat,
                        archiveSize: UInt64?) -> String {
        var parts: [String] = []
        if listing.isSingleFile {
            parts.append("1 compressed file")
        } else if tree.fileCount == 0 && tree.folderCount == 0 {
            parts.append("Empty archive")
        } else {
            var counts = [count(tree.fileCount, "file", "files")]
            if tree.folderCount > 0 { counts.append(count(tree.folderCount, "folder", "folders")) }
            parts.append(counts.joined(separator: ", "))
        }
        if format == .tar {
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
            if format == .tar { return "Listing stopped after reading \(amount)" }
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
