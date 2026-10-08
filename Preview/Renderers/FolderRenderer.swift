import AppKit
import SwiftUI
import SpyglassKit

/// Folders: the folder's icon, item count, total size and date over a
/// Finder-style list of what's directly inside. The total size is added up
/// in the background and fills in when it's ready.
@MainActor
struct FolderRenderer: PreviewRenderer {

    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView {
        let result = await Task.detached(priority: .userInitiated) { () -> Result<FolderListing, Error> in
            Result { try FolderListing.read(at: url) }
        }.value
        switch result {
        case .success(let listing) where listing.itemCount == 0:
            return FallbackViews.hosting(FolderCard(url: url, message: "Empty folder"))
        case .success(let listing):
            return FallbackViews.withNote(FolderPreviewView(url: url, listing: listing), note: Self.note(for: listing))
        case .failure(FolderListingError.unreadable):
            return FallbackViews.hosting(FolderCard(url: url, message: "Spyglass can't read this folder's contents"))
        case .failure(let error):
            throw error
        }
    }

    static func note(for listing: FolderListing) -> String? {
        guard listing.isTruncated else { return nil }
        let shown = listing.entries.count.formatted()
        // Past the reading limit the rest of the folder is unseen, so the
        // rows shown aren't necessarily the first by name.
        return listing.itemCountIsLowerBound
            ? "Showing \(shown) of more than \(listing.itemCount.formatted()) items"
            : "Showing the first \(shown) of \(listing.itemCount.formatted()) items"
    }
}

/// The header and list, plus the background work that fills in folder item
/// counts and the total size.
@MainActor
final class FolderPreviewView: NSView {
    private let counting: Task<[String: Int], Never>
    private let measuring: Task<FolderSize, Never>

    init(url: URL, listing: FolderListing) {
        // Counting each subfolder's items is one directory read apiece, so
        // it runs on its own: a huge first subfolder would hold up the walk.
        let folders = listing.entries.filter { $0.kind == .folder }.map(\.name)
        counting = Task.detached(priority: .userInitiated) {
            FolderListing.itemCounts(in: url, folders: folders, isCancelled: { Task.isCancelled })
        }
        measuring = Task.detached(priority: .userInitiated) {
            FolderSize.measure(url, isCancelled: { Task.isCancelled })
        }
        super.init(frame: .zero)

        let summary = FolderSummary(listing: listing)
        let header = NSHostingView(rootView: FolderHeader(url: url, summary: summary))
        let list = FolderListView(folder: url, entries: listing.entries)
        for view in [header, list] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: header.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        Task { [counting, weak list] in
            let counts = await counting.value
            list?.show(itemCounts: counts)
        }
        Task { [measuring, weak summary, weak list] in
            let size = await measuring.value
            summary?.size = size
            list?.show(size)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        counting.cancel()
        measuring.cancel()
    }
}

// MARK: - Header

@MainActor
final class FolderSummary: ObservableObject {
    let listing: FolderListing
    /// nil while the walk is running.
    @Published var size: FolderSize?

    init(listing: FolderListing) {
        self.listing = listing
    }

    /// "28 items · 1.2 GB"
    var line: String {
        var parts = [listing.itemCountIsLowerBound
            ? "More than \(listing.itemCount.formatted()) items"
            : "\(listing.itemCount.formatted()) \(listing.itemCount == 1 ? "item" : "items")"]
        switch size?.total {
        case nil: parts.append("Calculating size…")
        case .exact(let bytes)?: parts.append(byteCountText(bytes))
        case .atLeast(let bytes)?: parts.append("at least \(byteCountText(bytes))")
        case .unknown?: break
        }
        return parts.joined(separator: " · ")
    }

    var help: String? {
        guard case .atLeast? = size?.total else { return nil }
        return "Spyglass stops adding up sizes after a second, or when it meets a folder it can't read."
    }
}

private struct FolderHeader: View {
    let name: String
    let icon: NSImage
    let modified: Date?
    @ObservedObject var summary: FolderSummary

    init(url: URL, summary: FolderSummary) {
        let values = try? url.resourceValues(forKeys: [.localizedNameKey, .contentModificationDateKey])
        name = values?.localizedName ?? url.lastPathComponent
        icon = NSWorkspace.shared.icon(forFile: url.path)
        modified = values?.contentModificationDate
        self.summary = summary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    Text(summary.line)
                        .help(summary.help ?? "")
                    if let modified {
                        Text("Modified \(FolderListView.dateFormatter.string(from: modified))")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Icon, name and a message, for a folder with nothing to list.
private struct FolderCard: View {
    let url: URL
    let message: String

    var body: some View {
        let values = try? url.resourceValues(forKeys: [.localizedNameKey, .contentModificationDateKey, .creationDateKey])
        VStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
            Text(values?.localizedName ?? url.lastPathComponent)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let modified = values?.contentModificationDate {
                    row("Modified", modified.formatted(date: .abbreviated, time: .shortened))
                }
                if let created = values?.creationDate {
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

// MARK: - List

/// The folder's items in a sortable table styled like the archive tree:
/// icon and name, size, kind, date. Folders stay above everything else in
/// every sort, as in Finder's default.
@MainActor
final class FolderListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private let folder: URL
    private var entries: [FolderEntry]
    /// Items inside each subfolder, by name, once counted.
    private var itemCounts: [String: Int] = [:]
    /// Bytes inside each package, by name, once the walk has added them up.
    private var packageSizes: [String: UInt64] = [:]
    private let table = NSTableView()
    private var icons: [String: NSImage] = [:]

    init(folder: URL, entries: [FolderEntry]) {
        self.folder = folder
        self.entries = entries
        super.init(frame: .zero)

        addColumn("name", title: "Name", width: 300, minWidth: 140, ascending: true)
        addColumn("size", title: "Size", width: 90, minWidth: 60, ascending: false, alignment: .right)
        addColumn("kind", title: "Kind", width: 150, minWidth: 80, ascending: true)
        addColumn("modified", title: "Date Modified", width: 150, minWidth: 100, ascending: false)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.style = .fullWidth
        table.rowHeight = ArchiveTreeView.rowHeight
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        // Already in this order; set before the data source so it doesn't sort again.
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.dataSource = self
        table.delegate = self

        documentView = table
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func tile() {
        super.tile()
        fitColumns(to: contentView.bounds.width)
    }

    /// Columns only shrink when the view does, not when it first appears
    /// narrower than their total, so the name column is sized here to take
    /// what the others leave. In a narrow preview Kind, then Date Modified,
    /// step aside rather than squeeze the names.
    private func fitColumns(to width: CGFloat) {
        guard width > 0, let name = column("name") else { return }
        let spacing = table.intercellSpacing.width
        func needed(_ columns: [NSTableColumn?]) -> CGFloat {
            columns.compactMap { $0 }.reduce(name.minWidth + spacing) { $0 + $1.width + spacing }
        }
        let size = column("size"), kind = column("kind"), modified = column("modified")
        let showKind = needed([size, kind, modified]) <= width
        let showDate = showKind || needed([size, modified]) <= width
        kind?.isHidden = !showKind
        modified?.isHidden = !showDate
        let others = needed([size, showKind ? kind : nil, showDate ? modified : nil]) - name.minWidth
        let target = max(name.minWidth, (width - others).rounded(.down))
        if abs(name.width - target) >= 1 { name.width = target }
    }

    private func column(_ id: String) -> NSTableColumn? {
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id))
    }

    func show(itemCounts: [String: Int]) {
        self.itemCounts = itemCounts
        refreshSizes()
    }

    func show(_ size: FolderSize) {
        packageSizes = size.childSizes
        refreshSizes()
    }

    private func refreshSizes() {
        if table.sortDescriptors.first?.key == "size" {
            sort()
        } else if let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "size" }) {
            table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<entries.count), columnIndexes: [column])
        }
    }

    private func addColumn(_ id: String, title: String, width: CGFloat, minWidth: CGFloat,
                           ascending: Bool, alignment: NSTextAlignment = .left) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.headerCell.alignment = alignment
        column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: ascending)
        table.addTableColumn(column)
    }

    // MARK: - Sorting

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sort()
    }

    private func sort() {
        guard let descriptor = table.sortDescriptors.first else { return }
        let ascending = descriptor.ascending
        let byName: (FolderEntry, FolderEntry) -> Bool = { FolderListing.inFinderOrder($0, $1) }
        let ordered: (FolderEntry, FolderEntry) -> Bool
        switch descriptor.key {
        case "size":
            ordered = { [itemCounts, packageSizes] a, b in
                let x = Self.sortableSize(a, itemCounts, packageSizes), y = Self.sortableSize(b, itemCounts, packageSizes)
                return x != y ? x < y : byName(a, b)
            }
        case "kind":
            ordered = { a, b in
                switch (a.typeDescription ?? "").localizedStandardCompare(b.typeDescription ?? "") {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return byName(a, b)
                }
            }
        case "modified":
            ordered = { a, b in
                let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
                return x != y ? x < y : byName(a, b)
            }
        default:
            ordered = byName
        }
        entries.sort { a, b in
            let aIsFolder = a.kind == .folder, bIsFolder = b.kind == .folder
            if aIsFolder != bIsFolder { return aIsFolder }
            return ascending ? ordered(a, b) : ordered(b, a)
        }
        table.reloadData()
    }

    /// Item count for a folder, bytes for anything else; -1 while unknown.
    private static func sortableSize(_ entry: FolderEntry, _ itemCounts: [String: Int],
                                     _ packageSizes: [String: UInt64]) -> Int64 {
        switch entry.kind {
        case .folder: return itemCounts[entry.name].map(Int64.init) ?? -1
        case .package: return packageSizes[entry.name].map { Int64(clamping: $0) } ?? -1
        case .file: return entry.size.map { Int64(clamping: $0) } ?? -1
        case .symlink: return -1
        }
    }

    // MARK: - Cells

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue, row < entries.count else { return nil }
        let entry = entries[row]
        switch column {
        case "name":
            let cell = reusableCell(column, withImage: true)
            cell.imageView?.image = icon(for: entry)
            cell.textField?.stringValue = entry.name
            return cell
        case "size":
            let cell = reusableCell(column, withImage: false, monospacedDigits: true)
            cell.textField?.alignment = .right
            let text = sizeText(for: entry)
            cell.textField?.stringValue = text ?? "--"
            cell.textField?.textColor = text == nil || entry.kind == .folder ? .tertiaryLabelColor : .secondaryLabelColor
            return cell
        case "kind":
            let cell = reusableCell(column, withImage: false)
            cell.textField?.stringValue = entry.typeDescription ?? "--"
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        default:
            let cell = reusableCell(column, withImage: false, monospacedDigits: true)
            cell.textField?.stringValue = entry.modified.map { Self.dateFormatter.string(from: $0) } ?? "--"
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }
    }

    private func sizeText(for entry: FolderEntry) -> String? {
        switch entry.kind {
        case .file:
            return entry.size.map(byteCountText)
        case .package:
            return packageSizes[entry.name].map(byteCountText)
        case .folder:
            return itemCounts[entry.name].map { "\($0.formatted()) \($0 == 1 ? "item" : "items")" }
        case .symlink:
            return nil
        }
    }

    private func reusableCell(_ id: String, withImage: Bool, monospacedDigits: Bool = false) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("cell." + id)
        if let cell = table.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let fontSize = NSFont.systemFontSize(for: .small) + 1
        let label = NSTextField(labelWithString: "")
        label.font = monospacedDigits
            ? .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
            : .systemFont(ofSize: fontSize)
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(label)
        cell.textField = label
        var constraints = [
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ]
        if withImage {
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            ]
        } else {
            constraints.append(label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    /// The item's own icon, as Finder shows it, looked up once per row.
    private func icon(for entry: FolderEntry) -> NSImage {
        if let cached = icons[entry.name] { return cached }
        let image = NSWorkspace.shared.icon(forFile: folder.appendingPathComponent(entry.name).path)
        icons[entry.name] = image
        return image
    }
}
