import AppKit
import CoreText

/// One value in a data grid.
enum GridCell: Sendable {
    case text(String)
    /// Display text plus the value used for sorting.
    case number(String, Double)
    case null
    case blob(bytes: Int)

    /// SQLite's own order across types: NULL, numbers, text, blobs.
    fileprivate var rank: Int {
        switch self {
        case .null: return 0
        case .number: return 1
        case .text: return 2
        case .blob: return 3
        }
    }

    fileprivate var displayText: String {
        switch self {
        case .text(let text), .number(let text, _): return text
        case .null: return "NULL"
        case .blob(let bytes): return "<\(bytes) bytes>"
        }
    }

    fileprivate static func ordered(_ a: GridCell, _ b: GridCell) -> ComparisonResult {
        switch (a, b) {
        case let (.number(_, x), .number(_, y)):
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case let (.text(x), .text(y)):
            return x.localizedStandardCompare(y)
        case let (.blob(x), .blob(y)):
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        default:
            return a.rank < b.rank ? .orderedAscending : (a.rank > b.rank ? .orderedDescending : .orderedSame)
        }
    }
}

struct GridColumn: Sendable {
    var title: String
    var toolTip: String?
}

/// Everything a `DataGridView` shows, prepared off the main thread: cells,
/// how many text lines each row needs, and a starting width per column.
struct GridData: Sendable {
    static let maxLinesPerRow = 4

    let columns: [GridColumn]
    let rows: [[GridCell]]
    let lineCounts: [Int]
    let columnWidths: [CGFloat]

    init(columns: [GridColumn], rows: [[GridCell]]) {
        self.columns = columns
        self.rows = rows
        lineCounts = rows.map { row in
            var lines = 1
            for case .text(let text) in row {
                let count = text.utf8.reduce(1) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
                lines = max(lines, min(count, Self.maxLinesPerRow))
                if lines == Self.maxLinesPerRow { break }
            }
            return lines
        }
        columnWidths = Self.measureWidths(columns: columns, rows: rows)
    }

    /// Widths from the header and the first rows, measured with Core Text
    /// (safe off the main thread). Long values are clipped, not measured.
    private static func measureWidths(columns: [GridColumn], rows: [[GridCell]]) -> [CGFloat] {
        let header = CTFontCreateUIFontForLanguage(.emphasizedSystem, GridStyle.headerFontSize, nil)
        let body = CTFontCreateUIFontForLanguage(.system, GridStyle.fontSize, nil)
        let mono = NSFont.monospacedSystemFont(ofSize: GridStyle.monoFontSize, weight: .regular) as CTFont
        func width(_ text: Substring, _ font: CTFont?) -> CGFloat {
            guard !text.isEmpty, let font else { return 0 }
            let string = NSAttributedString(string: String(text.prefix(80)), attributes: [.font: font])
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(string), nil, nil, nil))
        }
        let sample = rows.prefix(100)
        return columns.indices.map { column in
            // Header text plus room for the sort indicator.
            var widest = width(Substring(columns[column].title), header) + 22
            for row in sample where column < row.count {
                let cell = row[column]
                let firstLine = cell.displayText.split(separator: "\n", maxSplits: 1,
                                                       omittingEmptySubsequences: false).first ?? ""
                let font: CTFont?
                switch cell {
                case .text: font = body
                case .number, .blob: font = mono
                case .null: font = body
                }
                widest = max(widest, width(firstLine, font) + 2 * GridStyle.cellPadding + 4)
            }
            return min(max(widest.rounded(.up), 48), 360)
        }
    }
}

enum GridStyle {
    static let fontSize: CGFloat = 12
    static let monoFontSize: CGFloat = 11.5
    static let headerFontSize: CGFloat = 11
    static let cellPadding: CGFloat = 5
    static let rowPadding: CGFloat = 5
}

/// A scrollable, sortable NSTableView over a `GridData`. Columns are made
/// at runtime, which SwiftUI's `Table` can't do on macOS 14.0.
@MainActor
final class DataGridView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {

    private let data: GridData
    /// Display order: row indices into `data.rows`.
    private var order: [Int]
    private var sortTask: Task<Void, Never>?
    private let table = NSTableView()

    private static let bodyFont = NSFont.systemFont(ofSize: GridStyle.fontSize)
    private static let monoFont = NSFont.monospacedSystemFont(ofSize: GridStyle.monoFontSize, weight: .regular)
    private static let nullFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
    private static let lineHeight = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)

    init(data: GridData) {
        self.data = data
        order = Array(data.rows.indices)
        super.init(frame: .zero)

        for (index, column) in data.columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            tableColumn.title = column.title
            tableColumn.headerToolTip = column.toolTip
            tableColumn.width = data.columnWidths[index]
            tableColumn.minWidth = 32
            tableColumn.maxWidth = 4_000
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: String(index), ascending: true)
            table.addTableColumn(tableColumn)
        }
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.intercellSpacing = NSSize(width: 1, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsColumnReordering = true
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self

        documentView = table
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func numberOfRows(in tableView: NSTableView) -> Int {
        order.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let lines = data.lineCounts[order[row]]
        return Self.lineHeight * CGFloat(lines) + GridStyle.rowPadding
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Int(tableColumn.identifier.rawValue) else { return nil }
        let view = tableView.makeView(withIdentifier: GridCellView.identifier, owner: self) as? GridCellView
            ?? GridCellView()
        let cells = data.rows[order[row]]
        view.show(column < cells.count ? cells[column] : .text(""))
        return view
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key, let column = Int(key) else { return }
        let ascending = descriptor.ascending
        let rows = data.rows
        let current = order
        sortTask?.cancel()
        // 10,000 localized string comparisons are worth keeping off the
        // main thread.
        sortTask = Task { [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) {
                current.sorted { a, b in
                    let x = column < rows[a].count ? rows[a][column] : .null
                    let y = column < rows[b].count ? rows[b][column] : .null
                    switch GridCell.ordered(x, y) {
                    case .orderedAscending: return ascending
                    case .orderedDescending: return !ascending
                    case .orderedSame: return a < b
                    }
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.order = sorted
            self.table.reloadData()
        }
    }

    /// Single-cell configuration, shared by every column.
    fileprivate static func style(_ field: NSTextField, for cell: GridCell) {
        field.stringValue = cell.displayText
        switch cell {
        case .text:
            field.font = bodyFont
            field.textColor = .labelColor
            field.alignment = .natural
        case .number:
            field.font = monoFont
            field.textColor = .labelColor
            field.alignment = .right
        case .null:
            field.font = nullFont
            field.textColor = .tertiaryLabelColor
            field.alignment = .natural
        case .blob:
            field.font = monoFont
            field.textColor = .secondaryLabelColor
            field.alignment = .natural
        }
    }
}

private final class GridCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GridCell")

    private let field = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        field.translatesAutoresizingMaskIntoConstraints = false
        field.maximumNumberOfLines = GridData.maxLinesPerRow
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GridStyle.cellPadding),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -GridStyle.cellPadding),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ cell: GridCell) {
        DataGridView.style(field, for: cell)
    }
}
