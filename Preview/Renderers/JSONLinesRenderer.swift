import AppKit
import SpyglassKit

/// `.jsonl` / `.ndjson`: one row per line, one column per key. Files whose
/// lines aren't objects show as highlighted JSON instead.
struct JSONLinesRenderer: PreviewRenderer {

    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView {
        let parsed = await Task.detached(priority: .userInitiated) { () -> Result<(GridData, String?), Error> in
            Result {
                let table = try JSONLines.parse(contentsOf: url)
                return (Self.gridData(table), Self.note(for: table))
            }
        }.value
        switch parsed {
        case .success(let (data, note)):
            return FallbackViews.withNote(DataGridView(data: data), note: note)
        case .failure(JSONLinesError.notTabular), .failure(JSONLinesError.tooManyInvalidLines):
            // Arrays or scalars per line, or a JSON document with a .jsonl
            // name: still worth reading as code.
            return try await CodeRenderer().makeView(for: url, kind: .code(language: "json"), settings: settings)
        case .failure(let error):
            throw error
        }
    }

    /// A "Line" column first, so sorting by it restores the file's order
    /// and a bad line can be found in an editor.
    nonisolated static func gridData(_ table: JSONLinesTable) -> GridData {
        let columns = [GridColumn(title: "Line", toolTip: "Line number in the file")]
            + table.columns.map { GridColumn(title: $0.isEmpty ? "\"\"" : $0, toolTip: $0) }
        let rows = table.rows.map { row -> [GridCell] in
            switch row {
            case .values(let line, let values):
                return [lineCell(line)] + values.map { value -> GridCell in
                    switch value {
                    case nil: return .text("")
                    case .string(let text)?: return .text(text)
                    case .number(let text, let number)?: return .number(text, number)
                    case .bool(let flag)?: return .text(flag ? "true" : "false")
                    case .null?: return .null
                    case .nested(let json)?: return .text(json)
                    }
                }
            case .invalid(let line, let reason):
                return [lineCell(line), .error(reason)]
            }
        }
        return GridData(columns: columns, rows: rows)
    }

    private nonisolated static func lineCell(_ line: Int) -> GridCell {
        .number(String(line), Double(line))
    }

    nonisolated static func note(for table: JSONLinesTable) -> String? {
        var parts: [String] = []
        if table.rowsTruncated || table.bytesTruncated {
            var rows = "the first \(table.rows.count.formatted()) rows"
            if table.bytesTruncated {
                let limit = ByteCountFormatter.string(fromByteCount: Int64(JSONLines.byteLimit), countStyle: .file)
                rows += " (the first \(limit) of the file)"
            }
            parts.append(rows)
        }
        if table.columnsTruncated {
            parts.append("the first \(JSONLines.columnLimit.formatted()) keys")
        }
        guard !parts.isEmpty else { return nil }
        return "Showing " + parts.joined(separator: " and ")
    }
}
