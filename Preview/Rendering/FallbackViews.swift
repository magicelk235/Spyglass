import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SpyglassKit

/// The two last-resort previews, plus the banner renderers put above a
/// preview that only shows part of a file.
@MainActor
enum FallbackViews {

    /// Read-only monospaced text.
    static func plainText(_ text: String, truncated: Bool, fontSize: Double) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = text
        let note = truncated
            ? "Showing the first \(ByteCountFormatter.string(fromByteCount: Int64(TextSniffer.readLimit), countStyle: .file))"
            : nil
        return withNote(scroll, note: note)
    }

    static func fileCard(for url: URL) -> NSView {
        hosting(FileCardView(url: url))
    }

    /// Puts a `NoteBanner` above `content` when `note` is non-nil; the
    /// content fills the rest of the space.
    static func withNote(_ content: NSView, note: String?) -> NSView {
        guard let note else { return content }
        let container = NSView()
        let banner = NSHostingView(rootView: NoteBanner(note))
        for view in [banner, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: container.topAnchor),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: banner.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    static func hosting<V: View>(_ root: V) -> NSView {
        NSHostingView(rootView: root)
    }
}

/// Thin banner above a preview: how much of an over-limit file is shown,
/// or what was done to the file to show it (a signed profile unwrapped).
struct NoteBanner: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
    }
}

/// Icon, name, kind, size, and dates for a file nothing else can preview.
struct FileCardView: View {
    let url: URL

    private var values: URLResourceValues? {
        try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey,
                                          .contentModificationDateKey, .creationDateKey])
    }

    var body: some View {
        let v = values
        VStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 96, height: 96)
            Text(url.lastPathComponent)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let kind = v?.contentType?.localizedDescription {
                Text(kind).font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if v?.isDirectory != true, let size = v?.fileSize {
                    row("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
                if let modified = v?.contentModificationDate {
                    row("Modified", modified.formatted(date: .abbreviated, time: .shortened))
                }
                if let created = v?.creationDate {
                    row("Created", created.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.callout)
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}
