import AppKit
import SwiftUI
import SpyglassKit

/// A SQLite database: tables and views in a sidebar, the selected one's
/// first rows in a grid.
struct SQLiteRenderer: PreviewRenderer {

    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView {
        let (reader, objects, first) = try await Task.detached(priority: .userInitiated) {
            let reader = try SQLiteReader(url: url)
            let objects = try reader.objects()
            // Leaves most of the render budget for the rest; a slow first
            // view shows its own error instead of losing the whole preview.
            let first = objects.first.map { SQLiteBrowserView.load($0, from: reader, timeout: 1) }
            return (reader, objects, first)
        }.value
        return SQLiteBrowserView(url: url, reader: reader, objects: objects, first: first)
    }
}

/// The rows of one table or view, ready to show, or why they can't be.
enum LoadedObject: Sendable {
    case rows(GridData, truncated: Bool)
    case failed(String)
}

@MainActor
final class SQLiteBrowserView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    private enum SidebarRow {
        case group(String)
        case object(SQLiteObject)
    }

    private let url: URL
    private let reader: SQLiteReader
    private let rows: [SidebarRow]
    private var counts: [String: SQLiteRowCount] = [:]
    private let sidebar = NSTableView()
    private let content = NSView()
    private var loadTask: Task<Void, Never>?
    private var countTask: Task<Void, Never>?
    /// Set while selecting the first object, whose rows are already loaded.
    private var selectingPreloaded = false

    init(url: URL, reader: SQLiteReader, objects: [SQLiteObject], first: LoadedObject?) {
        self.url = url
        self.reader = reader
        var rows: [SidebarRow] = []
        let tables = objects.filter { $0.kind == .table }
        let views = objects.filter { $0.kind == .view }
        if !tables.isEmpty { rows.append(.group("Tables")); rows += tables.map(SidebarRow.object) }
        if !views.isEmpty { rows.append(.group("Views")); rows += views.map(SidebarRow.object) }
        self.rows = rows
        super.init(frame: .zero)
        buildLayout()
        if let first, let index = rows.firstIndex(where: { if case .object = $0 { return true } else { return false } }) {
            // Show the preloaded rows without a second fetch.
            selectingPreloaded = true
            sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            selectingPreloaded = false
            show(first)
        } else {
            showMessage("This database has no tables.")
        }
        countRows(objects)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            loadTask?.cancel()
            countTask?.cancel()
        }
    }

    nonisolated static func load(_ object: SQLiteObject, from reader: SQLiteReader, timeout: TimeInterval = 5) -> LoadedObject {
        do {
            let result = try reader.rows(of: object.name, timeout: timeout)
            let types = Dictionary(object.columns.map { ($0.name, $0.declaredType) }, uniquingKeysWith: { a, _ in a })
            let columns = result.columns.map { name in
                let type = types[name].map { $0.isEmpty ? "No declared type" : $0 }
                return GridColumn(title: name, toolTip: type.map { "\(name): \($0)" } ?? name)
            }
            let cells = result.rows.map { $0.map(cell) }
            return .rows(GridData(columns: columns, rows: cells), truncated: result.truncated)
        } catch SQLiteReaderError.timedOut {
            return .failed("Reading its rows took too long.")
        } catch let SQLiteReaderError.sqlite(_, message) {
            return .failed(message)
        } catch {
            return .failed(String(describing: error))
        }
    }

    private nonisolated static func cell(_ value: SQLiteValue) -> GridCell {
        switch value {
        case .null: return .null
        case .integer(let value): return .number(String(value), Double(value))
        case .real(let value): return .number(String(value), value)
        case .text(let text, let truncated): return .text(truncated ? text + "…" : text)
        case .blob(let bytes): return .blob(bytes: bytes)
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("object"))
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        // Not .sourceList: its vibrant selection needs a key window and
        // draws as a black bar in a Quick Look panel that isn't.
        sidebar.style = .inset
        sidebar.backgroundColor = .clear
        sidebar.rowSizeStyle = .default
        sidebar.floatsGroupRows = false
        sidebar.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        sidebar.dataSource = self
        sidebar.delegate = self

        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.borderType = .noBorder

        // Not an NSBox: a separator box hugs its height hard enough to
        // shrink the window around it.
        let divider = SeparatorLine()

        for view in [sidebarScroll, divider, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let width = sidebarScroll.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.24)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            sidebarScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarScroll.topAnchor.constraint(equalTo: topAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            width,
            sidebarScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            sidebarScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            divider.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            content.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setContent(_ view: NSView) {
        content.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func show(_ loaded: LoadedObject) {
        switch loaded {
        case .rows(let data, let truncated):
            let note = truncated ? "Showing the first \(SQLiteReader.rowLimit) rows" : nil
            setContent(FallbackViews.withNote(DataGridView(data: data), note: note))
        case .failed(let message):
            showMessage("Couldn't read this \(selectedObject?.kind.rawValue ?? "table")", detail: message)
        }
    }

    private func showMessage(_ text: String, detail: String? = nil) {
        let message = SQLiteMessage(text: text, detail: detail)
        setContent(NSHostingView(rootView: message))
    }

    private var selectedObject: SQLiteObject? {
        let index = sidebar.selectedRow
        guard rows.indices.contains(index), case .object(let object) = rows[index] else { return nil }
        return object
    }

    // MARK: - Loading

    private func load(_ object: SQLiteObject) {
        loadTask?.cancel()
        let reader = reader
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                SQLiteBrowserView.load(object, from: reader)
            }.value
            guard let self, !Task.isCancelled, self.selectedObject?.name == object.name else { return }
            self.show(loaded)
        }
    }

    /// Counts run on a second connection so they never hold up the rows of
    /// the table being looked at.
    private func countRows(_ objects: [SQLiteObject]) {
        let url = url
        let names = objects.map(\.name)
        countTask = Task { [weak self] in
            guard let counter = await Task.detached(operation: { try? SQLiteReader(url: url) }).value else { return }
            for name in names {
                let count = await Task.detached(priority: .utility) { counter.rowCount(of: name) }.value
                guard let self, !Task.isCancelled else { return }
                self.counts[name] = count
                if let row = self.rows.firstIndex(where: { if case .object(let o) = $0 { return o.name == name } else { return false } }) {
                    self.sidebar.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                }
            }
        }
    }

    // MARK: - Sidebar

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let title):
            let field = NSTextField(labelWithString: title)
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            field.textColor = .secondaryLabelColor
            let cell = NSTableCellView()
            cell.addSubview(field)
            cell.textField = field
            field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case .object(let object):
            let cell = tableView.makeView(withIdentifier: ObjectCellView.identifier, owner: self) as? ObjectCellView
                ?? ObjectCellView()
            cell.show(object, count: counts[object.name])
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selectingPreloaded, let object = selectedObject else { return }
        load(object)
    }
}

private final class ObjectCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SQLiteObject")

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)
        for view in [icon, name, count] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ object: SQLiteObject, count rowCount: SQLiteRowCount?) {
        let symbol = object.kind == .table ? "tablecells" : "eye"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: object.kind.rawValue)
        icon.contentTintColor = .secondaryLabelColor
        name.stringValue = object.name
        let columns = object.columns.count == 1 ? "1 column" : "\(object.columns.count) columns"
        switch rowCount {
        case .exact(let n)?:
            count.stringValue = n.formatted()
            toolTip = "\(object.name)\n\(n == 1 ? "1 row" : "\(n.formatted()) rows"), \(columns)"
        case .atLeast(let n)?:
            count.stringValue = "\(n)+"
            toolTip = "\(object.name)\nMore than \(n) rows (counting took too long), \(columns)"
        case .unknown?:
            count.stringValue = "unknown"
            toolTip = "\(object.name)\nRow count unknown (counting took too long), \(columns)"
        case nil:
            count.stringValue = ""
            toolTip = "\(object.name)\n\(columns)"
        }
    }
}

private final class SeparatorLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        dirtyRect.fill()
    }
}

private struct SQLiteMessage: View {
    let text: String
    let detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(text).font(.headline).foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.tertiary).textSelection(.enabled)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
