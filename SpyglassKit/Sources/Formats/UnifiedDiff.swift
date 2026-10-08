import Foundation

/// A parsed unified diff covering one or more files: `git diff`,
/// `git format-patch`, `diff -u` / `diff -ru` and `svn diff` output.
///
/// Previews read only the head of large files, so the input may stop anywhere.
/// A hunk shorter than its header claims, or a file header with no hunks, is
/// kept as far as it goes instead of failing the whole preview.
public struct UnifiedDiff: Equatable, Sendable, Encodable {
    /// Text before the first file, e.g. the commit message of `git format-patch` output. Empty when none.
    public var preamble: String
    public var files: [File]

    public init(preamble: String = "", files: [File]) {
        self.preamble = preamble
        self.files = files
    }

    /// One file's section of the diff.
    public struct File: Equatable, Sendable, Encodable {
        public enum Status: String, Sendable, Encodable { case modified, added, deleted, renamed, copied }

        /// nil when the old side is /dev/null.
        public var oldPath: String?
        /// nil when the new side is /dev/null.
        public var newPath: String?
        public var status: Status
        /// From `old mode` or `deleted file mode`, e.g. "100644".
        public var oldMode: String?
        /// From `new mode` or `new file mode`.
        public var newMode: String?
        /// `similarity index 95%` gives 95.
        public var similarity: Int?
        /// Set by `Binary files … differ` or `GIT binary patch`.
        public var isBinary: Bool
        public var hunks: [Hunk]
        public var additions: Int
        public var deletions: Int

        public init(
            oldPath: String? = nil, newPath: String? = nil, status: Status = .modified,
            oldMode: String? = nil, newMode: String? = nil, similarity: Int? = nil,
            isBinary: Bool = false, hunks: [Hunk] = [], additions: Int = 0, deletions: Int = 0
        ) {
            self.oldPath = oldPath
            self.newPath = newPath
            self.status = status
            self.oldMode = oldMode
            self.newMode = newMode
            self.similarity = similarity
            self.isBinary = isBinary
            self.hunks = hunks
            self.additions = additions
            self.deletions = deletions
        }
    }

    /// One `@@ -a,b +c,d @@` block.
    public struct Hunk: Equatable, Sendable, Encodable {
        public var oldStart: Int
        public var oldCount: Int
        public var newStart: Int
        public var newCount: Int
        /// Text after the closing @@ (usually the enclosing function), trimmed. Empty if none.
        public var heading: String
        public var lines: [Line]

        public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, heading: String = "", lines: [Line] = []) {
            self.oldStart = oldStart
            self.oldCount = oldCount
            self.newStart = newStart
            self.newCount = newCount
            self.heading = heading
            self.lines = lines
        }
    }

    public struct Line: Equatable, Sendable, Encodable {
        public enum Kind: String, Sendable, Encodable { case context, added, removed, noNewline }

        public var kind: Kind
        /// The line without its ' ', '+' or '-' marker. For `noNewline`, the
        /// text after "\ ".
        public var text: String
        /// Set for context and removed lines.
        public var oldLine: Int?
        /// Set for context and added lines.
        public var newLine: Int?

        public init(kind: Kind, text: String, oldLine: Int? = nil, newLine: Int? = nil) {
            self.kind = kind
            self.text = text
            self.oldLine = oldLine
            self.newLine = newLine
        }
    }

    /// Parses `text`. Throws `.noFiles` when it contains no file section and
    /// `.malformedHunkHeader` for an `@@` line that doesn't follow the grammar.
    public static func parse(_ text: String) throws -> UnifiedDiff {
        var parser = DiffParser(lines: splitLines(text))
        return try parser.run()
    }

    /// Splits on "\n" and drops one trailing "\r" per line. Works on UTF-8
    /// bytes because "\r\n" is a single Character in Swift and would never
    /// match a plain "\n" split.
    static func splitLines(_ text: String) -> [Substring] {
        var lines: [Substring] = []
        let utf8 = text.utf8
        var start = utf8.startIndex
        var index = utf8.startIndex
        while index < utf8.endIndex {
            if utf8[index] == Byte.newline {
                lines.append(trimmingCarriageReturn(text[start..<index]))
                start = utf8.index(after: index)
            }
            index = utf8.index(after: index)
        }
        if start < utf8.endIndex {
            lines.append(trimmingCarriageReturn(text[start...]))
        }
        return lines
    }

    private static func trimmingCarriageReturn(_ line: Substring) -> Substring {
        guard line.utf8.last == Byte.carriageReturn else { return line }
        return line[..<line.utf8.index(before: line.endIndex)]
    }
}

public enum UnifiedDiffError: Error, Equatable {
    /// The text has no file section at all.
    case noFiles
    /// An `@@` line that isn't `@@ -a[,b] +c[,d] @@`, or a combined-diff
    /// `@@@` header. `line` is 1-based.
    case malformedHunkHeader(line: Int)
}

private enum Byte {
    static let newline = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let tab = UInt8(ascii: "\t")
    static let space = UInt8(ascii: " ")
    static let quote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let slash = UInt8(ascii: "/")
    static let plus = UInt8(ascii: "+")
    static let minus = UInt8(ascii: "-")
    static let comma = UInt8(ascii: ",")
    static let at = UInt8(ascii: "@")
    static let zero = UInt8(ascii: "0")
    static let nine = UInt8(ascii: "9")
    static let seven = UInt8(ascii: "7")
}

private extension Substring {
    func hasBytePrefix(_ prefix: String) -> Bool {
        utf8.starts(with: prefix.utf8)
    }

    /// The rest of the line after `count` leading ASCII bytes.
    func droppingBytes(_ count: Int) -> Substring {
        guard let index = utf8.index(startIndex, offsetBy: count, limitedBy: endIndex) else {
            return self[endIndex...]
        }
        return self[index...]
    }

    /// The rest of the line after `prefix`, or nil if it doesn't start with it.
    func after(_ prefix: String) -> Substring? {
        hasBytePrefix(prefix) ? droppingBytes(prefix.utf8.count) : nil
    }

    /// First occurrence of an ASCII `needle`, searched byte by byte.
    func firstIndex(ofBytes needle: String) -> Index? {
        let target = Array(needle.utf8)
        guard let head = target.first else { return nil }
        var index = utf8.startIndex
        while index < utf8.endIndex {
            if utf8[index] == head, utf8[index...].starts(with: target) { return index }
            index = utf8.index(after: index)
        }
        return nil
    }
}

/// The file being assembled, plus the header facts that decide its paths and
/// status once the whole section has been read.
private struct PendingFile {
    var file = UnifiedDiff.File()
    /// Prefix letters such as ("a", "b") when the `diff --git` line uses them.
    /// Plain diffs never get these, so their paths are kept as written.
    var prefixes: (old: UInt8, new: UInt8)?
    var sawPathLines = false
    var oldIsDevNull = false
    var newIsDevNull = false
    var isNewFile = false
    var isDeletedFile = false
    var renameFrom: String?
    var renameTo: String?
    var copyFrom: String?
    var copyTo: String?

    var hasPaths: Bool {
        file.oldPath != nil || file.newPath != nil || oldIsDevNull || newIsDevNull
    }

    func stripped(_ path: String, letter: UInt8?) -> String {
        guard let letter else { return path }
        let bytes = path.utf8
        guard bytes.count > 2, bytes.starts(with: [letter, Byte.slash]) else { return path }
        let start = bytes.index(bytes.startIndex, offsetBy: 2)
        return String(path[start...])
    }

    mutating func setOld(_ path: String?) {
        oldIsDevNull = path == nil
        file.oldPath = path.map { stripped($0, letter: prefixes?.old) }
    }

    mutating func setNew(_ path: String?) {
        newIsDevNull = path == nil
        file.newPath = path.map { stripped($0, letter: prefixes?.new) }
    }

    func finished() -> UnifiedDiff.File {
        var result = file
        if renameFrom != nil || renameTo != nil {
            result.oldPath = renameFrom ?? result.oldPath
            result.newPath = renameTo ?? result.newPath
        } else if copyFrom != nil || copyTo != nil {
            result.oldPath = copyFrom ?? result.oldPath
            result.newPath = copyTo ?? result.newPath
        }
        if isNewFile || oldIsDevNull {
            result.status = .added
            result.oldPath = nil
        } else if isDeletedFile || newIsDevNull {
            result.status = .deleted
            result.newPath = nil
        } else if renameFrom != nil || renameTo != nil {
            result.status = .renamed
        } else if copyFrom != nil || copyTo != nil {
            result.status = .copied
        } else {
            result.status = .modified
        }
        return result
    }
}

private struct DiffParser {
    let lines: [Substring]
    var index = 0
    var files: [UnifiedDiff.File] = []
    var current: PendingFile?
    var preambleEnd: Int?

    // The open hunk lives in plain fields rather than an optional so lines
    // append in place instead of copying the array each time.
    var inHunk = false
    var hunk = UnifiedDiff.Hunk(oldStart: 0, oldCount: 0, newStart: 0, newCount: 0)
    var oldRemaining = 0
    var newRemaining = 0
    var oldLine = 0
    var newLine = 0

    init(lines: [Substring]) {
        self.lines = lines
    }

    mutating func run() throws -> UnifiedDiff {
        while index < lines.count {
            let line = lines[index]
            if inHunk {
                if consumeHunkLine(line) {
                    index += 1
                    continue
                }
                closeHunk()
            }
            try readHeaderLine(line)
        }
        closeHunk()
        closeFile()
        guard !files.isEmpty else { throw UnifiedDiffError.noFiles }
        return UnifiedDiff(preamble: preamble(), files: files)
    }

    // MARK: Files

    var inFileHeader: Bool {
        guard let current else { return false }
        return current.file.hunks.isEmpty && !inHunk
    }

    mutating func startFile() {
        closeHunk()
        closeFile()
        if files.isEmpty && preambleEnd == nil { preambleEnd = index }
        current = PendingFile()
    }

    mutating func closeFile() {
        guard let current else { return }
        files.append(current.finished())
        self.current = nil
    }

    mutating func readHeaderLine(_ line: Substring) throws {
        if let rest = line.after("diff --git ") {
            startFile()
            readGitPaths(rest)
            index += 1
            return
        }
        // Plain `diff -u a b` / `diff -r` command lines. Requiring the file
        // header on the next line keeps prose such as "diff the two..." in a
        // commit message from opening a file.
        if line.hasBytePrefix("diff "), index + 1 < lines.count,
           lines[index + 1].hasBytePrefix("--- ") || lines[index + 1].hasBytePrefix("Binary files ") {
            startFile()
            index += 1
            return
        }
        if let old = line.after("--- "), index + 1 < lines.count, let new = lines[index + 1].after("+++ ") {
            let waiting = inFileHeader && current?.sawPathLines == false
            if !waiting { startFile() }
            current?.sawPathLines = true
            current?.setOld(Self.path(old))
            current?.setNew(Self.path(new))
            index += 2
            return
        }
        if let (old, new) = Self.binaryFilesPaths(line) {
            if !inFileHeader || current?.file.isBinary == true { startFile() }
            current?.file.isBinary = true
            if current?.hasPaths == false {
                current?.setOld(Self.path(old))
                current?.setNew(Self.path(new))
            }
            index += 1
            return
        }
        guard current != nil else {
            index += 1
            return
        }
        if line.hasBytePrefix("@@") {
            try openHunk(line)
            index += 1
            return
        }
        if inFileHeader {
            readExtendedHeader(line)
        } else {
            index += 1
        }
    }

    mutating func readGitPaths(_ rest: Substring) {
        let (old, new) = Self.splitGitPaths(rest)
        current?.prefixes = Self.prefixLetters(old, new)
        current?.setOld(old)
        current?.setNew(new)
    }

    /// Git's extended header lines between `diff --git` and the first hunk.
    mutating func readExtendedHeader(_ line: Substring) {
        index += 1
        if let mode = line.after("old mode ") {
            current?.file.oldMode = Self.trimmed(mode)
        } else if let mode = line.after("new mode ") {
            current?.file.newMode = Self.trimmed(mode)
        } else if let mode = line.after("deleted file mode ") {
            current?.file.oldMode = Self.trimmed(mode)
            current?.isDeletedFile = true
        } else if let mode = line.after("new file mode ") {
            current?.file.newMode = Self.trimmed(mode)
            current?.isNewFile = true
        } else if let path = line.after("rename from ") {
            current?.renameFrom = Self.path(path) ?? String(path)
        } else if let path = line.after("rename to ") {
            current?.renameTo = Self.path(path) ?? String(path)
        } else if let path = line.after("copy from ") {
            current?.copyFrom = Self.path(path) ?? String(path)
        } else if let path = line.after("copy to ") {
            current?.copyTo = Self.path(path) ?? String(path)
        } else if let value = line.after("similarity index ") {
            current?.file.similarity = Self.leadingNumber(value)
        } else if line.hasBytePrefix("GIT binary patch") {
            current?.file.isBinary = true
            skipBinaryPatch()
        }
        // `index abc..def`, `dissimilarity index`, svn's `Index:` and `====`
        // lines and anything unrecognised carry nothing the preview shows.
    }

    /// Skips the base85 `literal` / `delta` blocks after `GIT binary patch`.
    /// Each block ends at a blank line; git writes a forward and a reverse one.
    mutating func skipBinaryPatch() {
        while index < lines.count {
            let line = lines[index]
            if line.hasBytePrefix("diff ") { return }
            index += 1
            if line.isEmpty {
                guard index < lines.count,
                      lines[index].hasBytePrefix("literal ") || lines[index].hasBytePrefix("delta ")
                else { return }
            }
        }
    }

    // MARK: Hunks

    mutating func openHunk(_ line: Substring) throws {
        guard let header = Self.hunkHeader(line) else {
            throw UnifiedDiffError.malformedHunkHeader(line: index + 1)
        }
        closeHunk()
        hunk = UnifiedDiff.Hunk(
            oldStart: header.oldStart, oldCount: header.oldCount,
            newStart: header.newStart, newCount: header.newCount, heading: header.heading)
        oldRemaining = header.oldCount
        newRemaining = header.newCount
        oldLine = header.oldStart
        newLine = header.newStart
        inHunk = true
    }

    mutating func closeHunk() {
        guard inHunk else { return }
        current?.file.hunks.append(hunk)
        hunk.lines = []
        inHunk = false
    }

    /// Adds `line` to the open hunk, or returns false when it can't belong to
    /// it: the counts are used up, or the line has no valid marker.
    mutating func consumeHunkLine(_ line: Substring) -> Bool {
        let marker = line.utf8.first
        if marker == Byte.backslash {
            var text = line.droppingBytes(1)
            if text.utf8.first == Byte.space { text = text.droppingBytes(1) }
            hunk.lines.append(.init(kind: .noNewline, text: String(text)))
            return true
        }
        switch marker {
        case nil, Byte.space?:
            // Editors often strip the lone space of an empty context line.
            guard oldRemaining > 0, newRemaining > 0 else { return false }
            hunk.lines.append(.init(kind: .context, text: String(line.droppingBytes(1)), oldLine: oldLine, newLine: newLine))
            oldRemaining -= 1
            newRemaining -= 1
            oldLine += 1
            newLine += 1
        case Byte.minus?:
            guard oldRemaining > 0 else { return false }
            hunk.lines.append(.init(kind: .removed, text: String(line.droppingBytes(1)), oldLine: oldLine))
            oldRemaining -= 1
            oldLine += 1
            current?.file.deletions += 1
        case Byte.plus?:
            guard newRemaining > 0 else { return false }
            hunk.lines.append(.init(kind: .added, text: String(line.droppingBytes(1)), newLine: newLine))
            newRemaining -= 1
            newLine += 1
            current?.file.additions += 1
        default:
            return false
        }
        return true
    }

    struct HunkHeader {
        var oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        var heading: String
    }

    /// `@@ -a[,b] +c[,d] @@ heading`; an omitted count means 1.
    static func hunkHeader(_ line: Substring) -> HunkHeader? {
        let bytes = line.utf8
        var cursor = bytes.startIndex

        func take(_ byte: UInt8) -> Bool {
            guard cursor < bytes.endIndex, bytes[cursor] == byte else { return false }
            cursor = bytes.index(after: cursor)
            return true
        }
        // Nine digits is far beyond any real file and keeps the line counters
        // well clear of overflow.
        func number() -> Int? {
            var value = 0
            var digits = 0
            while cursor < bytes.endIndex, bytes[cursor] >= Byte.zero, bytes[cursor] <= Byte.nine {
                guard digits < 9 else { return nil }
                value = value * 10 + Int(bytes[cursor] - Byte.zero)
                digits += 1
                cursor = bytes.index(after: cursor)
            }
            return digits > 0 ? value : nil
        }
        func range(_ sign: UInt8) -> (start: Int, count: Int)? {
            guard take(sign), let start = number() else { return nil }
            guard take(Byte.comma) else { return (start, 1) }
            guard let count = number() else { return nil }
            return (start, count)
        }

        guard take(Byte.at), take(Byte.at), take(Byte.space),
              let old = range(Byte.minus), take(Byte.space),
              let new = range(Byte.plus), take(Byte.space),
              take(Byte.at), take(Byte.at)
        else { return nil }
        let heading = line[cursor...].trimmingCharacters(in: .whitespaces)
        return HunkHeader(oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count, heading: heading)
    }

    // MARK: Paths

    /// A path from a `---`/`+++`, `rename`/`copy` or `Binary files` line:
    /// unquoted if git quoted it, cut at a tab (diff timestamps, svn
    /// revisions), and nil for /dev/null.
    static func path(_ text: Substring) -> String? {
        let path: String
        if let (unquoted, _) = unquote(text) {
            path = unquoted
        } else if let tab = text.utf8.firstIndex(of: Byte.tab) {
            path = String(text[..<tab])
        } else {
            path = String(text)
        }
        return path == "/dev/null" ? nil : path
    }

    /// Splits the two paths of `diff --git A B`, still carrying their prefixes.
    static func splitGitPaths(_ rest: Substring) -> (String, String) {
        if let (old, end) = unquote(rest) {
            var tail = rest[end...]
            if tail.utf8.first == Byte.space { tail = tail.droppingBytes(1) }
            return (old, unquote(tail)?.path ?? String(tail))
        }
        // Unquoted paths may contain spaces. Both sides name the same file
        // unless it was renamed (and then `rename from/to` give the real
        // paths), so the separating space is the middle byte.
        let bytes = rest.utf8
        let count = bytes.count
        if count % 2 == 1 {
            let middle = bytes.index(bytes.startIndex, offsetBy: count / 2)
            if bytes[middle] == Byte.space {
                let old = rest[..<middle]
                let new = rest[bytes.index(after: middle)...]
                if old == new || (prefixLetters(String(old), String(new)) != nil
                                  && old.utf8.dropFirst(2).elementsEqual(new.utf8.dropFirst(2))) {
                    return (String(old), String(new))
                }
            }
        }
        if let split = rest.firstIndex(ofBytes: " b/") ?? rest.utf8.firstIndex(of: Byte.space) {
            return (String(rest[..<split]), String(rest[bytes.index(after: split)...]))
        }
        return (String(rest), String(rest))
    }

    /// The source/destination prefix letters when both paths carry one:
    /// `a/`+`b/`, or the `i/ w/ c/ o/` of `diff.mnemonicPrefix`.
    static func prefixLetters(_ old: String, _ new: String) -> (old: UInt8, new: UInt8)? {
        let oldLetters = Array("aciow".utf8)
        let newLetters = Array("bciow".utf8)
        let o = Array(old.utf8.prefix(2))
        let n = Array(new.utf8.prefix(2))
        guard o.count == 2, n.count == 2, o[1] == Byte.slash, n[1] == Byte.slash,
              oldLetters.contains(o[0]), newLetters.contains(n[0]), o[0] != n[0]
        else { return nil }
        return (o[0], n[0])
    }

    /// The two paths of `Binary files X and Y differ`.
    static func binaryFilesPaths(_ line: Substring) -> (Substring, Substring)? {
        guard let body = line.after("Binary files "), body.utf8.count > " differ".utf8.count,
              body.utf8.reversed().starts(with: " differ".utf8.reversed())
        else { return nil }
        let end = body.utf8.index(body.endIndex, offsetBy: -" differ".utf8.count)
        let paths = body[..<end]
        guard let split = paths.firstIndex(ofBytes: " and ") else { return nil }
        return (paths[..<split], paths[split...].droppingBytes(" and ".utf8.count))
    }

    /// Decodes a git C-style quoted path that starts at the first byte of
    /// `text`. Octal escapes are raw bytes, so `"caf\303\251"` is "café".
    /// Returns nil when `text` isn't quoted or the closing quote is missing.
    static func unquote(_ text: Substring) -> (path: String, end: Substring.Index)? {
        let bytes = text.utf8
        guard bytes.first == Byte.quote else { return nil }
        var decoded: [UInt8] = []
        var cursor = bytes.index(after: bytes.startIndex)
        while cursor < bytes.endIndex {
            let byte = bytes[cursor]
            cursor = bytes.index(after: cursor)
            if byte == Byte.quote {
                return (String(decoding: decoded, as: UTF8.self), cursor)
            }
            guard byte == Byte.backslash else {
                decoded.append(byte)
                continue
            }
            guard cursor < bytes.endIndex else { return nil }
            let escape = bytes[cursor]
            cursor = bytes.index(after: cursor)
            switch escape {
            case UInt8(ascii: "n"): decoded.append(0x0A)
            case UInt8(ascii: "t"): decoded.append(0x09)
            case UInt8(ascii: "r"): decoded.append(0x0D)
            case UInt8(ascii: "a"): decoded.append(0x07)
            case UInt8(ascii: "b"): decoded.append(0x08)
            case UInt8(ascii: "f"): decoded.append(0x0C)
            case UInt8(ascii: "v"): decoded.append(0x0B)
            case Byte.zero...Byte.seven:
                var value = Int(escape - Byte.zero)
                for _ in 0..<2 {
                    guard cursor < bytes.endIndex, bytes[cursor] >= Byte.zero, bytes[cursor] <= Byte.seven else { break }
                    value = value * 8 + Int(bytes[cursor] - Byte.zero)
                    cursor = bytes.index(after: cursor)
                }
                decoded.append(UInt8(truncatingIfNeeded: value))
            default:
                // Covers \\ and \" as well as escapes git never writes,
                // which are kept as the escaped character.
                decoded.append(escape)
            }
        }
        return nil
    }

    static func trimmed(_ text: Substring) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    static func leadingNumber(_ text: Substring) -> Int? {
        let digits = text.utf8.prefix { $0 >= Byte.zero && $0 <= Byte.nine }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        return digits.reduce(0) { $0 * 10 + Int($1 - Byte.zero) }
    }

    // MARK: Preamble

    /// Everything before the first file, minus trailing blank lines and the
    /// `Index:` / `====` lines svn puts in front of each file.
    func preamble() -> String {
        var end = preambleEnd ?? 0
        while end > 0 {
            let line = lines[end - 1]
            let isBlank = line.utf8.allSatisfy { $0 == Byte.space || $0 == Byte.tab }
            let isRule = !line.isEmpty && line.utf8.allSatisfy { $0 == UInt8(ascii: "=") }
            guard isBlank || isRule || line.hasBytePrefix("Index: ") else { break }
            end -= 1
        }
        return lines[0..<end].joined(separator: "\n")
    }
}
