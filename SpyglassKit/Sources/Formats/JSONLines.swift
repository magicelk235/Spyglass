import Foundation

/// A JSON Lines file as a table: one row per line, one column per top-level
/// key, in the order keys first appear.
public struct JSONLinesTable: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case string(String)
        /// The number as written in the file, and its value for sorting.
        case number(String, Double)
        case bool(Bool)
        case null
        /// An array or object as compact JSON, keys in the file's order.
        case nested(String)
    }

    public enum Row: Equatable, Sendable {
        /// One value per column; nil where the line has no such key.
        case values(line: Int, [Value?])
        /// A line that isn't a JSON object, and why.
        case invalid(line: Int, reason: String)
    }

    public var columns: [String]
    public var rows: [Row]
    /// More lines followed the row limit.
    public var rowsTruncated: Bool
    /// The file is longer than the byte limit; the line cut by the limit is
    /// dropped.
    public var bytesTruncated: Bool
    /// Keys past the column limit are dropped.
    public var columnsTruncated: Bool
    public var invalidCount: Int

    public var truncated: Bool { rowsTruncated || bytesTruncated || columnsTruncated }
}

public enum JSONLinesError: Error, Equatable {
    case unreadable
    /// Nothing but blank lines.
    case empty
    /// The first line that parses isn't an object, or no object has a key:
    /// the file is JSON, but not a table.
    case notTabular
    /// More than a tenth of the lines aren't JSON objects.
    case tooManyInvalidLines(invalid: Int, total: Int)
}

/// Reads `.jsonl` / `.ndjson`: one JSON value per line, blank lines allowed.
/// Each line is checked with JSONSerialization, then scanned again for its
/// keys, because a dictionary forgets the order they were written in. A bad
/// line becomes an error row rather than failing the file.
public enum JSONLines {

    public static let rowLimit = 10_000
    public static let byteLimit = 20 * 1024 * 1024
    public static let columnLimit = 200
    /// Characters kept of one value; longer ones end in "…".
    public static let valueLimit = 1_000

    static let chunkSize = 256 * 1024

    /// Reads `url` in chunks, stopping at the row or byte limit.
    public static func parse(contentsOf url: URL, rowLimit: Int = rowLimit,
                             byteLimit: Int = byteLimit) throws -> JSONLinesTable {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw JSONLinesError.unreadable }
        defer { try? handle.close() }
        var parser = Parser(rowLimit: rowLimit)
        var consumed = 0
        while !parser.isFull {
            let want = min(chunkSize, byteLimit + 1 - consumed)
            guard want > 0 else { break }
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: want) ?? Data()
            } catch {
                throw JSONLinesError.unreadable
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
    public static func parse(_ data: Data, rowLimit: Int = rowLimit) throws -> JSONLinesTable {
        var parser = Parser(rowLimit: rowLimit)
        try parser.feed(data)
        return try parser.finish(cutShort: false)
    }

    struct Parser {
        private let rowLimit: Int
        /// Bytes after the last complete line.
        private var pending: [UInt8] = []
        private var lineNumber = 0
        private var columns: [String] = []
        private var columnIndex: [String: Int] = [:]
        private var rows: [JSONLinesTable.Row] = []
        private var invalidCount = 0
        private var sawObject = false
        private var rowsTruncated = false
        private var columnsTruncated = false

        init(rowLimit: Int) {
            self.rowLimit = max(0, rowLimit)
        }

        /// The row limit is reached and a further row has started.
        var isFull: Bool { rowsTruncated }

        mutating func feed<Bytes: Collection>(_ bytes: Bytes) throws where Bytes.Element == UInt8 {
            guard !rowsTruncated else { return }
            // What's already pending has no line break, so the search
            // resumes at the new bytes; a long line isn't rescanned per chunk.
            var searchFrom = pending.count
            pending.append(contentsOf: bytes)
            var start = 0
            while !rowsTruncated, let newline = pending[searchFrom...].firstIndex(of: Byte.lf) {
                try line(start..<newline)
                start = newline + 1
                searchFrom = start
            }
            pending.removeSubrange(0..<start)
        }

        /// `cutShort` means the input stopped at the byte limit, so the line
        /// in progress is incomplete and is dropped.
        mutating func finish(cutShort: Bool) throws -> JSONLinesTable {
            if !rowsTruncated, !cutShort, !pending.isEmpty {
                try line(0..<pending.count)
            }
            pending = []
            let total = rows.count
            if invalidCount > 0, invalidCount * 10 > total {
                throw JSONLinesError.tooManyInvalidLines(invalid: invalidCount, total: total)
            }
            if total == 0 { throw cutShort ? JSONLinesError.notTabular : JSONLinesError.empty }
            if columns.isEmpty { throw JSONLinesError.notTabular }
            let width = columns.count
            let padded = rows.map { row -> JSONLinesTable.Row in
                guard case .values(let line, var values) = row, values.count < width else { return row }
                values.append(contentsOf: repeatElement(nil, count: width - values.count))
                return .values(line: line, values)
            }
            return JSONLinesTable(columns: columns, rows: padded, rowsTruncated: rowsTruncated,
                                  bytesTruncated: cutShort && !rowsTruncated,
                                  columnsTruncated: columnsTruncated, invalidCount: invalidCount)
        }

        private mutating func line(_ range: Range<Int>) throws {
            lineNumber += 1
            var lower = range.lowerBound, upper = range.upperBound
            // A byte order mark, usually at the start of the file but also
            // where two files were concatenated.
            if upper - lower >= 3, pending[lower] == 0xEF, pending[lower + 1] == 0xBB, pending[lower + 2] == 0xBF {
                lower += 3
            }
            while lower < upper, Byte.isWhitespace(pending[lower]) { lower += 1 }
            while upper > lower, Byte.isWhitespace(pending[upper - 1]) { upper -= 1 }
            guard lower < upper else { return }
            guard rows.count < rowLimit else {
                rowsTruncated = true
                return
            }
            let bytes = pending[lower..<upper]
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])
            } catch {
                rows.append(.invalid(line: lineNumber, reason: Self.reason(for: error, columnOffset: lower - range.lowerBound)))
                invalidCount += 1
                return
            }
            guard object is NSDictionary else {
                // The first value decides whether this is a table at all.
                guard sawObject else { throw JSONLinesError.notTabular }
                rows.append(.invalid(line: lineNumber, reason: object is NSArray
                    ? "An array, not an object" : "A single value, not an object"))
                invalidCount += 1
                return
            }
            sawObject = true
            let values = bytes.withUnsafeBufferPointer { scanObject($0) }
            rows.append(.values(line: lineNumber, values))
        }

        /// "Invalid JSON at column 12: badly formed object", so the start
        /// still says what's wrong when a narrow column cuts the rest.
        /// JSONSerialization counts columns from 0 in the trimmed text it
        /// was given, and always says "line 1".
        private static func reason(for error: Error, columnOffset: Int) -> String {
            guard var text = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String, !text.isEmpty else {
                return "Invalid JSON"
            }
            var place = ""
            if let marker = text.range(of: " around line 1, column ") {
                let digits = text[marker.upperBound...].prefix { $0.isASCII && $0.isNumber }
                if let column = Int(digits) { place = " at column \(column + columnOffset + 1)" }
                text = String(text[..<marker.lowerBound])
            }
            if text.hasSuffix(".") { text.removeLast() }
            return "Invalid JSON\(place): " + text.prefix(1).lowercased() + text.dropFirst()
        }

        // MARK: - Scanning a valid object

        // These run only on bytes JSONSerialization has accepted, so they
        // need no error reporting; every index is still bounds-checked.

        /// The line's top-level values, placed by column. New keys add
        /// columns until the column limit.
        private mutating func scanObject(_ b: UnsafeBufferPointer<UInt8>) -> [JSONLinesTable.Value?] {
            var values = [JSONLinesTable.Value?](repeating: nil, count: columns.count)
            guard b.first == Byte.openBrace else { return values }
            var i = 1
            while true {
                skipWhitespace(b, &i)
                guard i < b.count, b[i] == Byte.quote else { break }
                let key = Self.string(b, &i, limit: Int.max)
                skipWhitespace(b, &i)
                guard i < b.count, b[i] == Byte.colon else { break }
                i += 1
                skipWhitespace(b, &i)
                let value = Self.value(b, &i)
                if let index = column(for: key) {
                    if index >= values.count {
                        values.append(contentsOf: repeatElement(nil, count: index - values.count + 1))
                    }
                    values[index] = value
                }
                skipWhitespace(b, &i)
                guard i < b.count, b[i] == Byte.comma else { break }
                i += 1
            }
            return values
        }

        private mutating func column(for key: String) -> Int? {
            if let index = columnIndex[key] { return index }
            guard columns.count < JSONLines.columnLimit else {
                columnsTruncated = true
                return nil
            }
            columnIndex[key] = columns.count
            columns.append(key)
            return columns.count - 1
        }

        private func skipWhitespace(_ b: UnsafeBufferPointer<UInt8>, _ i: inout Int) {
            while i < b.count, Byte.isWhitespace(b[i]) { i += 1 }
        }

        private static func value(_ b: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> JSONLinesTable.Value {
            guard i < b.count else { return .null }
            switch b[i] {
            case Byte.quote:
                return .string(string(b, &i, limit: JSONLines.valueLimit))
            case Byte.openBrace, Byte.openBracket:
                return .nested(compactContainer(b, &i))
            case UInt8(ascii: "t"), UInt8(ascii: "f"), UInt8(ascii: "n"):
                let first = b[i]
                while i < b.count, b[i] >= UInt8(ascii: "a"), b[i] <= UInt8(ascii: "z") { i += 1 }
                return first == UInt8(ascii: "n") ? .null : .bool(first == UInt8(ascii: "t"))
            default:
                let start = i
                while i < b.count, !Byte.endsScalar(b[i]) { i += 1 }
                let text = String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
                return .number(text, Double(text) ?? 0)
            }
        }

        /// The string starting at the quote at `i`, unescaped; `i` ends past
        /// the closing quote. Only the first `limit` characters are kept.
        private static func string(_ b: UnsafeBufferPointer<UInt8>, _ i: inout Int, limit: Int) -> String {
            i += 1
            let start = i
            var escaped = false
            while i < b.count, b[i] != Byte.quote {
                if b[i] == Byte.backslash {
                    escaped = true
                    i += 1
                }
                i += 1
            }
            let end = min(i, b.count)
            i = min(i + 1, b.count)
            // UTF-8 needs at most 4 bytes per character, and "\uD83D\uDE00"
            // is the longest escaped spelling of one, so this many bytes
            // always covers `limit` characters.
            var cap = limit == Int.max ? end : min(end, start &+ limit &* (escaped ? 12 : 4))
            // Cut between characters, not inside one.
            while cap > start, cap < end, b[cap] & 0xC0 == 0x80 { cap -= 1 }
            let raw = UnsafeBufferPointer(rebasing: b[start..<cap])
            let text = escaped ? unescape(raw) : String(decoding: raw, as: UTF8.self)
            return cut(text, alreadyCut: cap < end, limit: limit)
        }

        /// An array or object with the whitespace between tokens removed.
        private static func compactContainer(_ b: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> String {
            let cap = JSONLines.valueLimit * 4
            var out: [UInt8] = []
            var depth = 0
            var overflowed = false
            func keep<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
                for byte in bytes {
                    guard out.count < cap else {
                        overflowed = true
                        return
                    }
                    out.append(byte)
                }
            }
            while i < b.count {
                let byte = b[i]
                if byte == Byte.quote {
                    let start = i
                    i += 1
                    while i < b.count, b[i] != Byte.quote {
                        i += b[i] == Byte.backslash ? 2 : 1
                    }
                    i = min(i + 1, b.count)
                    keep(UnsafeBufferPointer(rebasing: b[start..<i]))
                    continue
                }
                i += 1
                if Byte.isWhitespace(byte) { continue }
                keep(CollectionOfOne(byte))
                if byte == Byte.openBrace || byte == Byte.openBracket {
                    depth += 1
                } else if byte == Byte.closeBrace || byte == Byte.closeBracket {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
            // Don't leave half a UTF-8 sequence at a cut.
            if overflowed {
                while let last = out.last, last & 0xC0 == 0x80 { out.removeLast() }
                if let last = out.last, last >= 0xC0 { out.removeLast() }
            }
            return cut(String(decoding: out, as: UTF8.self), alreadyCut: overflowed, limit: JSONLines.valueLimit)
        }

        private static func cut(_ text: String, alreadyCut: Bool, limit: Int) -> String {
            if !alreadyCut, text.utf8.count <= limit { return text }
            if !alreadyCut, text.count <= limit { return text }
            return String(text.prefix(limit)) + "…"
        }

        /// JSON string escapes; `\u` pairs combine into one character and a
        /// lone surrogate becomes U+FFFD.
        private static func unescape(_ raw: UnsafeBufferPointer<UInt8>) -> String {
            var out: [UInt8] = []
            out.reserveCapacity(raw.count)
            var j = 0
            func hex4(at index: Int) -> UInt32? {
                guard index + 4 <= raw.count else { return nil }
                var value: UInt32 = 0
                for k in index..<(index + 4) {
                    guard let digit = Byte.hexValue(raw[k]) else { return nil }
                    value = value << 4 | digit
                }
                return value
            }
            func append(_ scalar: Unicode.Scalar) {
                out.append(contentsOf: String(Character(scalar)).utf8)
            }
            while j < raw.count {
                let byte = raw[j]
                guard byte == Byte.backslash else {
                    out.append(byte)
                    j += 1
                    continue
                }
                // A string cut at the value limit can end inside an escape.
                guard j + 1 < raw.count else { break }
                let escape = raw[j + 1]
                j += 2
                switch escape {
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard let unit = hex4(at: j) else { return String(decoding: out, as: UTF8.self) }
                    j += 4
                    if (0xD800...0xDBFF).contains(unit), j + 6 <= raw.count,
                       raw[j] == Byte.backslash, raw[j + 1] == UInt8(ascii: "u"),
                       let low = hex4(at: j + 2), (0xDC00...0xDFFF).contains(low) {
                        j += 6
                        append(Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) ?? "\u{FFFD}")
                    } else {
                        append(Unicode.Scalar(unit) ?? "\u{FFFD}")
                    }
                default:
                    // \" \\ \/ stand for themselves.
                    out.append(escape)
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }

    private enum Byte {
        static let lf = UInt8(ascii: "\n")
        static let quote = UInt8(ascii: "\"")
        static let backslash = UInt8(ascii: "\\")
        static let colon = UInt8(ascii: ":")
        static let comma = UInt8(ascii: ",")
        static let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
        static let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")

        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        /// What can follow a number or literal.
        static func endsScalar(_ byte: UInt8) -> Bool {
            byte == comma || byte == closeBrace || byte == closeBracket || isWhitespace(byte)
        }

        static func hexValue(_ byte: UInt8) -> UInt32? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(byte - UInt8(ascii: "A") + 10)
            default: return nil
            }
        }
    }
}
