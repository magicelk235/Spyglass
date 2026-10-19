import AppKit
import UniformTypeIdentifiers
import SpyglassKit

/// "1.2 MB", and "0 bytes" where ByteCountFormatter would say "Zero KB".
func byteCountText(_ value: UInt64) -> String {
    byteCountFormatter.string(fromByteCount: Int64(clamping: value))
}

private let byteCountFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter
}()

/// A Finder-style list of an archive's files: collapsible folders, size and
/// date columns, sortable by any column. NSOutlineView only asks for the
/// rows on screen, so 50,000 entries cost no more than 50.
@MainActor
final class ArchiveTreeView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let rowHeight: CGFloat = 20

    private let tree: ArchiveTree
    private let outline = NSOutlineView()
    private var icons: [String: NSImage] = [:]

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// `expandAll` opens every folder (for short lists); otherwise only a
    /// lone top-level folder chain opens, the usual "project/" wrapper.
    init(tree: ArchiveTree, expandAll: Bool = false) {
        self.tree = tree
        super.init(frame: .zero)

        addColumn("name", title: "Name", width: 320, minWidth: 160, ascending: true)
        addColumn("size", title: "Size", width: 90, minWidth: 60, ascending: false, alignment: .right)
        addColumn("modified", title: "Date Modified", width: 170, minWidth: 100, ascending: false)
        outline.outlineTableColumn = outline.tableColumns.first
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        outline.style = .fullWidth
        outline.rowHeight = Self.rowHeight
        outline.indentationPerLevel = 14
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        outline.dataSource = self
        outline.delegate = self

        documentView = outline
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder

        if expandAll {
            outline.expandItem(nil, expandChildren: true)
        } else {
            var node = tree.root
            var depth = 0
            while node.children.count == 1, let only = node.children.first, only.isDirectory, depth < 16 {
                outline.expandItem(only)
                node = only
                depth += 1
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Height that shows every row of a fully expanded tree, for embedding.
    var fittingHeight: CGFloat {
        CGFloat(outline.numberOfRows) * (Self.rowHeight + outline.intercellSpacing.height)
            + (outline.headerView?.frame.height ?? 0) + 2
    }

    /// Embedded in a scrolling card, a list that already fits passes the
    /// wheel on so the card scrolls instead of the list rubber-banding.
    override func scrollWheel(with event: NSEvent) {
        if outline.frame.height <= contentView.bounds.height {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
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
        outline.addTableColumn(column)
    }

    // MARK: - Data source

    private func node(_ item: Any?) -> ArchiveNode {
        (item as? ArchiveNode) ?? tree.root
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(item).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(item).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !node(item).children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first else { return }
        let key: ArchiveTree.SortKey
        switch descriptor.key {
        case "size": key = .size
        case "modified": key = .modified
        default: key = .name
        }
        tree.sort(by: key, ascending: descriptor.ascending)
        outlineView.reloadData()
    }

    // MARK: - Cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue else { return nil }
        let node = node(item)
        switch column {
        case "name":
            let cell = reusableCell(column, withImage: true)
            cell.imageView?.image = icon(for: node)
            cell.textField?.attributedStringValue = title(for: node)
            return cell
        case "size":
            let cell = reusableCell(column, withImage: false)
            cell.textField?.alignment = .right
            let hasSize = node.kind == .file || (node.isDirectory && node.size > 0)
            cell.textField?.stringValue = hasSize
                ? byteCountText(node.size) : "--"
            cell.textField?.textColor = node.isDirectory ? .tertiaryLabelColor : .secondaryLabelColor
            return cell
        default:
            let cell = reusableCell(column, withImage: false)
            cell.textField?.stringValue = node.modified.map { Self.dateFormatter.string(from: $0) } ?? "--"
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }
    }

    private func reusableCell(_ id: String, withImage: Bool) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("cell." + id)
        if let cell = outline.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small) + 1)
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
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
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            ]
        } else {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small) + 1, weight: .regular)
            constraints.append(label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    /// The name, plus where a link points and whether the entry is encrypted.
    private func title(for node: ArchiveNode) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small) + 1)
        let title = NSMutableAttributedString(string: node.name, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ])
        if let target = node.linkTarget, !target.isEmpty {
            title.append(NSAttributedString(string: "  →  " + target, attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        if node.isEncrypted, let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Encrypted") {
            let attachment = NSTextAttachment()
            attachment.image = lock
            title.append(NSAttributedString(string: " "))
            title.append(NSAttributedString(attachment: attachment))
        }
        return title
    }

    private func icon(for node: ArchiveNode) -> NSImage {
        let key: String
        let type: UTType
        switch node.kind {
        case .directory:
            key = "/folder"
            type = .folder
        case .symlink, .hardlink:
            key = "/link"
            type = .aliasFile
        default:
            key = (node.name as NSString).pathExtension.lowercased()
            type = key.isEmpty ? .data : UTType(filenameExtension: key) ?? .data
        }
        if let cached = icons[key] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        icons[key] = image
        return image
    }
}
