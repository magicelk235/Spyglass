import Foundation

/// A parsed TSV/CSV file: the first row is the header, every row is padded
/// to the same width.
public struct DelimitedTable: Equatable, Sendable {
    public var header: [String]
    public var rows: [[String]]
    /// More data rows followed the row limit.
    public var rowsTruncated: Bool
    /// The file is longer than the byte limit; the row being read when the
    /// limit hit is dropped.
    public var bytesTruncated: Bool
    /// Some row was wider than the column limit; the extra fields are dropped.
    public var columnsTruncated: Bool

    public var truncated: Bool { rowsTruncated || bytesTruncated || columnsTruncated }
    public var columnCount: Int { header.count }
}

public enum DelimitedTextError: Error, Equatable {
    case unsupportedSeparator
    case invalidUTF8(row: Int)
    case unterminatedQuote
    case unreadable
}

/// RFC 4180-style reader for delimiter-separated text: quoted fields, `""`
/// escapes, separators and line breaks inside quotes, CRLF/LF/CR line ends,
/// and a leading UTF-8 BOM. Ragged rows are padded to the widest row.
///
/// It works on bytes, which is safe because the separator, quote, CR and LF
/// are ASCII and can never appear inside a multi-byte UTF-8 sequence. Each
/// field is decoded once it's complete, so invalid UTF-8 is caught per field.
public enum DelimitedText {

    public static let rowLimit = 10_000
    public static let byteLimit = 20 * 1024 * 1024
    /// Wider than anything a table view is pleasant to scroll; also bounds
    /// memory for a file that is all separators.
    public static let columnLimit = 1_000

    static let chunkSize = 256 * 1024

    /// Reads `url` in chunks, stopping at the row or byte limit.
    public static func parse(
        contentsOf url: URL,
        separator: Character,
        rowLimit: Int = rowLimit,
        byteLimit: Int = byteLimit
    ) throws -> DelimitedTable {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw DelimitedTextError.unreadable }
        defer { try? handle.close() }
        var parser = try Parser(separator: separator, rowLimit: rowLimit)
        var consumed = 0
        while !parser.isFull {
            let want = min(chunkSize, byteLimit + 1 - consumed)
            guard want > 0 else { break }
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: want) ?? Data()
            } catch {
                throw DelimitedTextError.unreadable
            }
            if chunk.isEmpty { break }
            consumed += chunk.count
            if consumed > byteLimit {
                // The extra byte only proves there is more; parse up to the limit.
                try parser.feed(chunk.dropLast())
                return try parser.finish(cutShort: true)
            }
            try parser.feed(chunk)
        }
        return try parser.finish(cutShort: false)
    }

    /// Parses an in-memory buffer; `data` is taken as the whole file.
    public static func parse(_ data: Data, separator: Character, rowLimit: Int = rowLimit) throws -> DelimitedTable {
        var parser = try Parser(separator: separator, rowLimit: rowLimit)
        try parser.feed(data)
        return try parser.finish(cutShort: false)
    }

    struct Parser {
        private enum State {
            case fieldStart
            case unquoted
            case quoted
            /// Just saw a `"` inside a quoted field: either an escaped quote
            /// or the closing quote.
            case quoteInQuoted
        }

        private static let quote = UInt8(ascii: "\"")
        private static let cr = UInt8(ascii: "\r")
        private static let lf = UInt8(ascii: "\n")

        private let separator: UInt8
        private let rowLimit: Int
        private var state = State.fieldStart
        private var field: [UInt8] = []
        private var record: [String] = []
        private var header: [String]?
        private var rows: [[String]] = []
        private var width = 0
        private var afterCR = false
        private var atFileStart = true
        private var bomBytesSeen = 0
        private var rowsTruncated = false
        private var columnsTruncated = false

        init(separator: Character, rowLimit: Int) throws {
            guard let ascii = separator.asciiValue,
                  ascii != Self.quote, ascii != Self.cr, ascii != Self.lf
            else { throw DelimitedTextError.unsupportedSeparator }
            self.separator = ascii
            self.rowLimit = max(0, rowLimit)
        }

        /// The row limit is reached and a further row has started.
        var isFull: Bool { rowsTruncated }

        mutating func feed<Bytes: Collection>(_ bytes: Bytes) throws where Bytes.Element == UInt8 {
            for byte in bytes {
                if rowsTruncated { return }
                if atFileStart, try skipBOM(byte) { continue }
                if afterCR {
                    afterCR = false
                    if byte == Self.lf { continue }
                }
                switch state {
                case .fieldStart:
                    if byte == Self.quote {
                        state = .quoted
                    } else if byte == separator {
                        try endField()
                    } else if byte == Self.cr || byte == Self.lf {
                        try endRecord(sawCR: byte == Self.cr)
                    } else {
                        field.append(byte)
                        state = .unquoted
                    }
                case .unquoted:
                    // A quote in the middle of an unquoted field is literal.
                    if byte == separator {
                        try endField()
                    } else if byte == Self.cr || byte == Self.lf {
                        try endRecord(sawCR: byte == Self.cr)
                    } else {
                        field.append(byte)
                    }
                case .quoted:
                    if byte == Self.quote {
                        state = .quoteInQuoted
                    } else {
                        field.append(byte)
                    }
                case .quoteInQuoted:
                    if byte == Self.quote {
                        field.append(byte)
                        state = .quoted
                    } else if byte == separator {
                        try endField()
                    } else if byte == Self.cr || byte == Self.lf {
                        try endRecord(sawCR: byte == Self.cr)
                    } else {
                        // Text after a closing quote (`"a"b`): keep it, like
                        // spreadsheet apps do.
                        field.append(byte)
                        state = .unquoted
                    }
                }
            }
        }

        /// `cutShort` means the input stopped at the byte limit, so the
        /// record in progress is incomplete and is dropped.
        mutating func finish(cutShort: Bool) throws -> DelimitedTable {
            if !rowsTruncated {
                if cutShort {
                    field.removeAll()
                    record.removeAll()
                } else {
                    if state == .quoted { throw DelimitedTextError.unterminatedQuote }
                    if state != .fieldStart || !field.isEmpty || !record.isEmpty {
                        try endRecord(sawCR: false)
                    }
                }
            }
            let header = (header ?? []) + Array(repeating: "", count: max(0, width - (header?.count ?? 0)))
            let padded = rows.map { row in
                row.count < width ? row + Array(repeating: "", count: width - row.count) : row
            }
            return DelimitedTable(header: header, rows: padded, rowsTruncated: rowsTruncated,
                                  bytesTruncated: cutShort && !rowsTruncated,
                                  columnsTruncated: columnsTruncated)
        }

        /// Swallows the UTF-8 BOM (EF BB BF) if the file starts with it.
        /// Returns true when `byte` was part of the BOM.
        private mutating func skipBOM(_ byte: UInt8) throws -> Bool {
            let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
            if byte == bom[bomBytesSeen] {
                bomBytesSeen += 1
                if bomBytesSeen == bom.count { atFileStart = false }
                return true
            }
            atFileStart = false
            if bomBytesSeen > 0 {
                // A partial BOM is not a BOM: the bytes belong to the field.
                field.append(contentsOf: bom.prefix(bomBytesSeen))
                state = .unquoted
                bomBytesSeen = 0
            }
            return false
        }

        private mutating func endField() throws {
            defer {
                field.removeAll(keepingCapacity: true)
                state = .fieldStart
            }
            guard record.count < DelimitedText.columnLimit else {
                columnsTruncated = true
                return
            }
            guard let text = String(bytes: field, encoding: .utf8) else {
                throw DelimitedTextError.invalidUTF8(row: rows.count + (header == nil ? 0 : 1))
            }
            record.append(text)
        }

        private mutating func endRecord(sawCR: Bool) throws {
            afterCR = sawCR
            try endField()
            defer { record.removeAll(keepingCapacity: true) }
            // A blank line is a single empty field; skip it rather than show
            // an empty row (it's usually the trailing newline).
            if record.count == 1, record[0].isEmpty { return }
            if header == nil {
                header = record
            } else if rows.count < rowLimit {
                rows.append(record)
            } else {
                rowsTruncated = true
                return
            }
            width = max(width, record.count)
        }
    }
}
