import AppKit
import SpyglassKit

/// TSV (and any other delimited text) as a sortable grid.
struct TableRenderer: PreviewRenderer {

    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView {
        guard case .table(let separator) = kind else { throw RenderError.unsupported("not a table") }
        let (data, note) = try await Task.detached(priority: .userInitiated) {
            let table = try DelimitedText.parse(contentsOf: url, separator: separator)
            guard !table.header.isEmpty else { throw RenderError.unsupported("empty table") }
            return (Self.gridData(table), Self.note(for: table))
        }.value
        return FallbackViews.withNote(DataGridView(data: data), note: note)
    }

    nonisolated static func gridData(_ table: DelimitedTable) -> GridData {
        let columns = table.header.enumerated().map { index, title in
            GridColumn(title: title.isEmpty ? "Column \(index + 1)" : title, toolTip: title.isEmpty ? nil : title)
        }
        // A column is numeric when every non-empty value is a number; it
        // then sorts by value and lines up on the right.
        let numeric = (0..<table.columnCount).map { column in
            var sawNumber = false
            for row in table.rows where !row[column].isEmpty {
                guard number(row[column]) != nil else { return false }
                sawNumber = true
            }
            return sawNumber
        }
        let rows = table.rows.map { row in
            row.enumerated().map { column, text -> GridCell in
                if numeric[column], let value = number(text) { return .number(text, value) }
                return .text(text)
            }
        }
        return GridData(columns: columns, rows: rows)
    }

    /// Plain decimal or scientific notation only: `Double` also takes "nan",
    /// "inf" and hex floats, which read as words in a table.
    nonisolated static func number(_ text: String) -> Double? {
        var digits = false
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digits = true
            case UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "e"), UInt8(ascii: "E"): break
            default: return nil
            }
        }
        return digits ? Double(text) : nil
    }

    nonisolated static func note(for table: DelimitedTable) -> String? {
        var parts: [String] = []
        if table.rowsTruncated || table.bytesTruncated {
            var rows = "the first \(table.rows.count.formatted()) rows"
            if table.bytesTruncated {
                let limit = ByteCountFormatter.string(fromByteCount: Int64(DelimitedText.byteLimit), countStyle: .file)
                rows += " (the first \(limit) of the file)"
            }
            parts.append(rows)
        }
        if table.columnsTruncated {
            parts.append("the first \(DelimitedText.columnLimit.formatted()) columns")
        }
        guard !parts.isEmpty else { return nil }
        return "Showing " + parts.joined(separator: " and ")
    }
}
