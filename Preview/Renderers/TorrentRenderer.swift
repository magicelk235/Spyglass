import AppKit
import SwiftUI
import SpyglassKit

/// `.torrent`: what it would download, from where, and its info hash, in
/// the same card as app and installer previews, with the files as a tree.
@MainActor
struct TorrentRenderer: PreviewRenderer {

    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView {
        let card = try await Task.detached(priority: .userInitiated) {
            Self.card(for: try TorrentInfo.read(at: url), url: url)
        }.value
        let contents = card.contents.map { tree -> ArchiveTreeView in
            let view = ArchiveTreeView(tree: tree, expandAll: tree.fileCount + tree.folderCount <= 200)
            // Torrents record no file dates; drop the column of dashes.
            (view.documentView as? NSTableView)?
                .tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("modified"))?.isHidden = true
            return view
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return NSHostingView(rootView: BundleCardView(card: card, icon: icon, contents: contents))
    }

    nonisolated static func card(for info: TorrentInfo, url: URL) -> BundleCard {
        let fileCount = info.files.count
        let files = "\(fileCount.formatted()) \(fileCount == 1 ? "file" : "files")"
        let title = info.name.isEmpty ? url.deletingPathExtension().lastPathComponent : info.name
        var card = BundleCard(title: title,
                              subtitle: [info.isPrivate ? "Private torrent" : "Torrent", files,
                                         byteCountText(info.totalSize)].joined(separator: " · "))

        var general: [BundleCard.Row] = [BundleCard.Row(label: "Total size", value: exactSize(info.totalSize))]
        if let count = info.pieceCount, let length = info.pieceLength {
            general.append(BundleCard.Row(label: "Pieces",
                                          value: "\(count.formatted()) × \(byteCountText(length))"))
        }
        if let date = info.creationDate {
            general.append(BundleCard.Row(label: "Created", value: date.formatted(date: .abbreviated, time: .shortened)))
        }
        if let creator = info.createdBy { general.append(BundleCard.Row(label: "Created by", value: creator)) }
        if let comment = info.comment { general.append(BundleCard.Row(label: "Comment", value: comment)) }
        if info.isPrivate {
            general.append(BundleCard.Row(label: "Private", value: "Yes: peers come only from its trackers"))
        }
        if info.trackers.isEmpty {
            general.append(BundleCard.Row(label: "Trackers", value: "None; peers are found through DHT"))
        }
        if !info.webSeeds.isEmpty {
            general.append(BundleCard.Row(label: "Web seeds", value: info.webSeeds.joined(separator: "\n")))
        }
        general.append(BundleCard.Row(label: "Format", value: format(info.version)))
        card.sections.append(BundleCard.Section(title: "General", rows: general))

        // The hash goes in the left-hand, primary column so it reads (and
        // selects) as the value; the algorithm is the annotation.
        var hashes: [BundleCard.Row] = []
        if let v1 = info.infoHashV1 { hashes.append(BundleCard.Row(label: v1, value: "v1 · SHA-1")) }
        if let v2 = info.infoHashV2 { hashes.append(BundleCard.Row(label: v2, value: "v2 · SHA-256")) }
        card.sections.append(BundleCard.Section(title: "Info hash", rows: hashes, style: .properties))

        if !info.trackers.isEmpty {
            card.sections.append(BundleCard.Section(
                title: "Trackers (\(info.trackers.count.formatted()))",
                rows: info.trackers.map { BundleCard.Row(label: $0.url, value: "Tier \($0.tier)") },
                style: .properties))
        }

        // A multi-file torrent downloads into a folder named after it.
        let entries = info.files.map { file in
            let path = (info.isSingleFile ? file.path : [title] + file.path).joined(separator: "/")
            return ArchiveEntry(path: path, kind: .file, size: file.length)
        }
        card.contents = ArchiveTree(entries: entries)
        return card
    }

    private nonisolated static func format(_ version: TorrentInfo.Version) -> String {
        switch version {
        case .v1: return "BitTorrent v1"
        case .v2: return "BitTorrent v2"
        case .hybrid: return "BitTorrent v1 and v2 (hybrid)"
        }
    }

    /// "1.2 GB (1,234,567,890 bytes)"
    private nonisolated static func exactSize(_ bytes: UInt64) -> String {
        let rounded = byteCountText(bytes)
        let exact = "\(bytes.formatted()) bytes"
        return bytes < 1_000 ? exact : "\(rounded) (\(exact))"
    }
}
