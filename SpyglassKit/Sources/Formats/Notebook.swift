import Foundation

public enum NotebookError: Error, Equatable {
    case malformed(String)
    /// nbformat 1 and 2.
    case unsupportedVersion(Int)
    /// Longer than the read limit, and not one cell ends within it.
    case tooLarge
}

/// A Jupyter notebook as the preview shows it: the cells in order, with each
/// output reduced to the one representation the page renders.
///
/// Reads nbformat 4 (and later), and nbformat 3 as far as it maps onto 4.
public struct Notebook: Equatable, Sendable {

    public struct Limits: Equatable, Sendable {
        /// Cells past this many are left out.
        public var maxCells: Int
        /// A longer file is read this far, and the cells that end within it are shown.
        public var maxFileSize: Int
        /// Bytes of base64 image data, outputs and attachments together. An
        /// image that doesn't fit in what's left becomes a placeholder.
        public var imageBudget: Int

        public init(maxCells: Int = 5_000, maxFileSize: Int = 20_000_000, imageBudget: Int = 15_000_000) {
            self.maxCells = maxCells
            self.maxFileSize = maxFileSize
            self.imageBudget = imageBudget
        }

        public static let standard = Limits()
    }

    public struct Cell: Equatable, Sendable {
        public enum Kind: String, Sendable { case markdown, code, raw }

        public var kind: Kind
        public var source: String
        public var executionCount: Int?
        public var outputs: [Output] = []
        /// Images a Markdown cell embeds as `attachment:name`.
        public var attachments: [Attachment] = []
    }

    public struct Attachment: Equatable, Sendable {
        public var name: String
        public var image: Image
    }

    public struct Image: Equatable, Sendable {
        public var mimeType: String
        public var base64: String
        /// Display size in points, when the notebook gives one (Retina figures do).
        public var width: Int?
        public var height: Int?
        /// "light" or "dark": the background a transparent image needs to stay legible.
        public var background: String?
    }

    public struct Output: Equatable, Sendable {
        public enum Content: Equatable, Sendable {
            case stream(name: String, text: ANSIText)
            case text(ANSIText)
            case html(String)
            case markdown(String)
            case latex(String)
            case image(Image)
            /// An image left out because the image budget was spent; `size`
            /// is roughly how many bytes it has.
            case omittedImage(mimeType: String, size: Int)
            /// The traceback, or the error's name and message when there's none.
            case error(ANSIText)
        }

        public var content: Content
        /// The `Out[n]` number of an execute result.
        public var executionCount: Int?
    }

    /// How much of an over-long file was read.
    public struct Cut: Equatable, Sendable {
        public var readBytes: Int
        public var fileSize: Int
    }

    /// highlight.js language id for the code cells; nil when the notebook
    /// doesn't name one the highlighter knows.
    public var language: String?
    public var cells: [Cell]
    /// Cells in what was read. More than `cells.count` when the cell cap left some out.
    public var cellCount: Int
    /// Images replaced by placeholders once the image budget was spent.
    public var omittedImageCount: Int
    /// Set when the file was longer than `Limits.maxFileSize`.
    public var cut: Cut?
}

// MARK: - Reading

extension Notebook {

    /// Reads a notebook file. A file longer than `limits.maxFileSize` is read
    /// that far and shows the cells that end within it.
    public static func read(at url: URL, limits: Limits = .standard) throws -> Notebook {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = max(0, limits.maxFileSize)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count > limit else { return try decode(data, limits: limits) }

        let fileSize = Int(clamping: try handle.seekToEnd())
        guard let leading = leadingCells(data.prefix(limit)) else { throw NotebookError.tooLarge }
        var notebook = try decode(leading, limits: limits)
        if notebook.language == nil {
            // Jupyter writes the metadata after the cells.
            let tailStart = max(limit, fileSize - 64 * 1024)
            try handle.seek(toOffset: UInt64(tailStart))
            notebook.language = try handle.readToEnd().flatMap(language(inTail:))
        }
        notebook.cut = Cut(readBytes: limit, fileSize: fileSize)
        return notebook
    }

    /// Decodes a whole notebook. Throws for anything that isn't notebook JSON.
    /// Individual cells and outputs that are missing fields are read as far as
    /// they go; entries of the wrong type are skipped.
    public static func decode(_ data: Data, limits: Limits = .standard) throws -> Notebook {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw NotebookError.malformed("The notebook isn't valid JSON")
        }
        guard let object = root as? [String: Any] else {
            throw NotebookError.malformed("The notebook isn't a JSON object")
        }
        let version = integer(object["nbformat"])
        if let version, version < 3 { throw NotebookError.unsupportedVersion(version) }
        var reader = Reader(limits: limits)

        if version == 3 || (version == nil && object["cells"] == nil && object["worksheets"] != nil) {
            guard let worksheets = object["worksheets"] as? [Any] else {
                throw NotebookError.malformed("The notebook has no worksheets")
            }
            let entries = worksheets.flatMap { (($0 as? [String: Any])?["cells"] as? [Any]) ?? [] }
                .compactMap { $0 as? [String: Any] }
            let firstCode = entries.first { $0["cell_type"] as? String == "code" }
            return Notebook(
                language: (firstCode?["language"] as? String).flatMap(highlightLanguage(named:)),
                cells: entries.prefix(max(0, limits.maxCells)).map { reader.version3Cell($0) },
                cellCount: entries.count,
                omittedImageCount: reader.omittedImages)
        }

        guard let entries = (object["cells"] as? [Any])?.compactMap({ $0 as? [String: Any] }) else {
            throw NotebookError.malformed("The notebook has no cells")
        }
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        return Notebook(
            language: language(kernelspec: metadata["kernelspec"], languageInfo: metadata["language_info"]),
            cells: entries.prefix(max(0, limits.maxCells)).map { reader.cell($0) },
            cellCount: entries.count,
            omittedImageCount: reader.omittedImages)
    }

    // MARK: Values

    /// Notebook text: a string, or an array of strings to join.
    static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let lines = value as? [Any] { return lines.compactMap { $0 as? String }.joined() }
        return nil
    }

    static func nonEmptyText(_ value: Any?) -> String? {
        text(value).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A JSON integer. Booleans, fractions and huge numbers don't count.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 1e15 else { return nil }
        return number.intValue
    }

    // MARK: Language

    /// highlight.js id for the kernel's language, from `kernelspec.language`,
    /// then `language_info.name`, then the language's file extension.
    static func language(kernelspec: Any?, languageInfo: Any?) -> String? {
        let spec = kernelspec as? [String: Any]
        let info = languageInfo as? [String: Any]
        for case let name? in [spec?["language"] as? String, info?["name"] as? String] {
            if let id = highlightLanguage(named: name) { return id }
        }
        if var ext = info?["file_extension"] as? String, !ext.isEmpty {
            if !ext.hasPrefix(".") { ext = "." + ext }
            if let id = CodeLanguage.language(forFilename: "notebook" + ext), id != "plaintext" { return id }
        }
        return nil
    }

    static func highlightLanguage(named name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let id = kernelLanguages[key] { return id }
        return knownLanguages.contains(key) ? key : nil
    }

    /// Kernel language names that differ from the highlight.js id.
    static let kernelLanguages: [String: String] = [
        "python2": "python", "python3": "python", "ipython": "python", "ipython2": "python", "ipython3": "python",
        "c++": "cpp", "c++11": "cpp", "c++14": "cpp", "c++17": "cpp", "c++20": "cpp", "c++23": "cpp",
        "c#": "csharp", "f#": "fsharp",
        "js": "javascript", "node.js": "javascript", "nodejs": "javascript",
        "sh": "bash", "shell": "bash", "zsh": "bash", "pwsh": "powershell",
        "octave": "matlab",
        "wolfram language": "mathematica", "mathematica": "mathematica",
        "racket": "scheme", "common lisp": "lisp",
        "stata": "stata", "maxima": "maxima",
    ]

    /// Ids the code view already uses, so they exist in the bundled highlighter.
    private static let knownLanguages = Set(CodeLanguage.byExtension.values).subtracting(["plaintext"])

    /// The language from the end of a file too long to read whole, where
    /// Jupyter writes the notebook's metadata.
    static func language(inTail tail: Data) -> String? {
        language(kernelspec: lastObject(named: "kernelspec", in: tail),
                 languageInfo: lastObject(named: "language_info", in: tail))
    }

    /// The complete JSON object value of the last `"name":` key in `data`.
    private static func lastObject(named name: String, in data: Data) -> [String: Any]? {
        guard let key = data.range(of: Data("\"\(name)\"".utf8), options: .backwards) else { return nil }
        let bytes = data[key.upperBound...]
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        guard let colon = bytes.firstIndex(where: { !whitespace.contains($0) }), bytes[colon] == UInt8(ascii: ":"),
              let open = bytes[(colon + 1)...].firstIndex(where: { !whitespace.contains($0) }),
              bytes[open] == UInt8(ascii: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in open..<bytes.endIndex {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 {
                    return (try? JSONSerialization.jsonObject(with: data[open...index])) as? [String: Any]
                }
            default: break
            }
        }
        return nil
    }

    // MARK: Over-long files

    /// The start of a notebook cut off mid-file, ended after the last
    /// complete cell and closed again (`]}`) so that it parses as a notebook
    /// with fewer cells. nil when no cell ends within `data`.
    static func leadingCells(_ data: Data) -> Data? {
        let end: Int? = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            let cellsKey = Array("cells".utf8)
            var depth = 0
            var index = 0
            // Inside the top-level object, a string is a key when it follows
            // "{" or ",". The last one names the value that comes next.
            var expectingKey = false
            var lastKeyIsCells = false
            var inCells = false
            var lastCellEnd: Int?
            while index < count {
                let byte = bytes[index]
                switch byte {
                case UInt8(ascii: "\""):
                    // Jump from quote to quote; one preceded by an odd number
                    // of backslashes is escaped.
                    let start = index + 1
                    var end = start
                    while true {
                        guard let found = memchr(base + end, 0x22, count - end) else { return lastCellEnd }
                        let quote = UnsafeRawPointer(found) - base
                        var backslashes = 0
                        while quote - backslashes - 1 >= start, bytes[quote - backslashes - 1] == 0x5C { backslashes += 1 }
                        end = quote
                        if backslashes % 2 == 0 { break }
                        end += 1
                    }
                    if depth == 1, expectingKey {
                        lastKeyIsCells = end - start == cellsKey.count && memcmp(base + start, cellsKey, cellsKey.count) == 0
                    }
                    index = end + 1
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                    if depth == 1 { expectingKey = byte == UInt8(ascii: "{") }
                    if depth == 2, byte == UInt8(ascii: "["), lastKeyIsCells { inCells = true }
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if inCells, depth == 2, byte == UInt8(ascii: "}") { lastCellEnd = index + 1 }
                    if depth <= 1 { inCells = false }
                case UInt8(ascii: ":"):
                    if depth == 1 { expectingKey = false }
                case UInt8(ascii: ","):
                    if depth == 1 { expectingKey = true }
                default:
                    break
                }
                index += 1
            }
            return lastCellEnd
        }
        guard let end else { return nil }
        var leading = Data(data.prefix(end))
        leading.append(contentsOf: Array("]}".utf8))
        return leading
    }
}

// MARK: - Cells and outputs

private struct Reader {
    var imageBytesLeft: Int
    var omittedImages = 0

    init(limits: Notebook.Limits) {
        imageBytesLeft = max(0, limits.imageBudget)
    }

    mutating func cell(_ object: [String: Any]) -> Notebook.Cell {
        let source = Notebook.text(object["source"]) ?? ""
        switch object["cell_type"] as? String {
        case "markdown":
            var cell = Notebook.Cell(kind: .markdown, source: source)
            if let attachments = object["attachments"] as? [String: Any] {
                cell.attachments = self.attachments(attachments)
            }
            return cell
        case "code":
            return Notebook.Cell(kind: .code, source: source,
                                 executionCount: Notebook.integer(object["execution_count"]),
                                 outputs: outputs(object["outputs"] as? [Any] ?? [], version: 4))
        default:
            return Notebook.Cell(kind: .raw, source: source)
        }
    }

    mutating func version3Cell(_ object: [String: Any]) -> Notebook.Cell {
        switch object["cell_type"] as? String {
        case "heading":
            let level = min(6, max(1, Notebook.integer(object["level"]) ?? 1))
            let title = Notebook.text(object["source"]) ?? ""
            return Notebook.Cell(kind: .markdown, source: String(repeating: "#", count: level) + " " + title)
        case "markdown":
            return Notebook.Cell(kind: .markdown, source: Notebook.text(object["source"]) ?? "")
        case "code":
            return Notebook.Cell(kind: .code, source: Notebook.text(object["input"]) ?? "",
                                 executionCount: Notebook.integer(object["prompt_number"]),
                                 outputs: outputs(object["outputs"] as? [Any] ?? [], version: 3))
        default:
            return Notebook.Cell(kind: .raw, source: Notebook.text(object["source"]) ?? "")
        }
    }

    /// nbformat 3 keeps each representation under a short name on the output itself.
    private static let version3Types = [
        "text": "text/plain", "html": "text/html", "svg": "image/svg+xml", "png": "image/png",
        "jpeg": "image/jpeg", "latex": "text/latex", "markdown": "text/markdown",
    ]

    mutating func outputs(_ entries: [Any], version: Int) -> [Notebook.Output] {
        var outputs: [Notebook.Output] = []
        // Consecutive writes to one stream show as one block, as in Jupyter.
        var stream: (name: String, text: String)?
        func endStream() {
            if let finished = stream, !finished.text.isEmpty {
                outputs.append(Notebook.Output(content: .stream(name: finished.name, text: ANSIText(finished.text))))
            }
            stream = nil
        }

        for case let object as [String: Any] in entries {
            guard let type = object["output_type"] as? String else { continue }
            if type == "stream" {
                let name = object[version == 3 ? "stream" : "name"] as? String ?? "stdout"
                let text = Notebook.text(object["text"]) ?? ""
                if stream?.name == name {
                    stream?.text += text
                } else {
                    endStream()
                    stream = (name, text)
                }
                continue
            }
            endStream()
            switch type {
            case "execute_result", "pyout", "display_data":
                let bundle: [String: Any]
                if version == 3 {
                    var mapped: [String: Any] = [:]
                    for (key, value) in object {
                        if let mimeType = Self.version3Types[key] { mapped[mimeType] = value }
                    }
                    bundle = mapped
                } else {
                    guard let data = object["data"] as? [String: Any] else { continue }
                    bundle = data
                }
                guard let content = representation(of: bundle, metadata: object["metadata"] as? [String: Any] ?? [:]) else { continue }
                let count = type == "display_data" ? nil : Notebook.integer(object[version == 3 ? "prompt_number" : "execution_count"])
                outputs.append(Notebook.Output(content: content, executionCount: count))
            case "error", "pyerr":
                outputs.append(Notebook.Output(content: .error(Self.errorText(object))))
            default:
                continue
            }
        }
        endStream()
        return outputs
    }

    private static func errorText(_ object: [String: Any]) -> ANSIText {
        let traceback = (object["traceback"] as? [Any] ?? []).compactMap { $0 as? String }
        if !traceback.isEmpty { return ANSIText(traceback.joined(separator: "\n")) }
        let summary = [object["ename"], object["evalue"]]
            .compactMap { $0 as? String }
            .filter { !$0.isEmpty }
            .joined(separator: ": ")
        return ANSIText(summary.isEmpty ? "Error" : summary)
    }

    /// The one representation of a mime bundle the page shows: an image
    /// (PNG, JPEG, then SVG), then HTML, Markdown, LaTeX, and plain text.
    private mutating func representation(of bundle: [String: Any], metadata: [String: Any]) -> Notebook.Output.Content? {
        if let image = image(in: bundle, metadata: metadata) { return image }
        if let html = Notebook.nonEmptyText(bundle["text/html"]) { return .html(html) }
        if let markdown = Notebook.nonEmptyText(bundle["text/markdown"]) { return .markdown(markdown) }
        if let latex = Notebook.nonEmptyText(bundle["text/latex"]) { return .latex(latex) }
        if let plain = Notebook.nonEmptyText(bundle["text/plain"]) { return .text(ANSIText(plain)) }
        return nil
    }

    /// The bundle's image, or a placeholder for it once the image budget is spent.
    private mutating func image(in bundle: [String: Any], metadata: [String: Any]) -> Notebook.Output.Content? {
        for mimeType in ["image/png", "image/jpeg"] {
            guard let base64 = Notebook.nonEmptyText(bundle[mimeType]) else { continue }
            let length = base64.utf8.count
            guard spend(length) else { return .omittedImage(mimeType: mimeType, size: length / 4 * 3) }
            return .image(Self.makeImage(mimeType, base64: base64, metadata: metadata))
        }
        // SVG is kept as text in the notebook. The page shows it as an image,
        // where it can't run scripts or load anything.
        let svgType = "image/svg+xml"
        guard let svg = Notebook.nonEmptyText(bundle[svgType]) else { return nil }
        let size = svg.utf8.count
        guard spend((size + 2) / 3 * 4) else { return .omittedImage(mimeType: svgType, size: size) }
        return .image(Self.makeImage(svgType, base64: Data(svg.utf8).base64EncodedString(), metadata: metadata))
    }

    private mutating func spend(_ length: Int) -> Bool {
        guard length <= imageBytesLeft else {
            omittedImages += 1
            return false
        }
        imageBytesLeft -= length
        return true
    }

    /// Width, height and needed background live under the image's mime type,
    /// or (matplotlib's `needs_background`) on the output itself.
    private static func makeImage(_ mimeType: String, base64: String, metadata: [String: Any]) -> Notebook.Image {
        let specific = metadata[mimeType] as? [String: Any] ?? [:]
        func value(_ key: String) -> Any? { specific[key] ?? metadata[key] }
        func dimension(_ key: String) -> Int? {
            Notebook.integer(value(key)).flatMap { (1...100_000).contains($0) ? $0 : nil }
        }
        let background = (value("needs_background") as? String).flatMap { $0 == "light" || $0 == "dark" ? $0 : nil }
        return Notebook.Image(mimeType: mimeType, base64: base64, width: dimension("width"), height: dimension("height"),
                              background: background)
    }

    private mutating func attachments(_ object: [String: Any]) -> [Notebook.Attachment] {
        object.keys.sorted().compactMap { name in
            guard let bundle = object[name] as? [String: Any],
                  case .image(let found) = image(in: bundle, metadata: [:]) else { return nil }
            return Notebook.Attachment(name: name, image: found)
        }
    }
}

// MARK: - Page payload

// What the web page reads (see `renderNotebook` in app.js). Cells are
// {"type", "source", "count", "outputs", "attachments"}; outputs carry a
// "type" of stream, text, html, markdown, latex, image, omitted or error.
// Unset fields are left out.
extension Notebook: Encodable {
    private enum CodingKeys: String, CodingKey { case language, cells }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(cells, forKey: .cells)
    }
}

extension Notebook.Cell: Encodable {
    private enum CodingKeys: String, CodingKey { case type, source, count, outputs, attachments }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(executionCount, forKey: .count)
        if !outputs.isEmpty { try container.encode(outputs, forKey: .outputs) }
        if !attachments.isEmpty { try container.encode(attachments, forKey: .attachments) }
    }
}

extension Notebook.Attachment: Encodable {
    private enum CodingKeys: String, CodingKey { case name, url }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode("data:\(image.mimeType);base64,\(image.base64)", forKey: .url)
    }
}

extension Notebook.Output: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, count, name, text, html, mime, data, width, height, background, size
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(executionCount, forKey: .count)
        switch content {
        case .stream(let name, let text):
            try container.encode("stream", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(text, forKey: .text)
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .html(let html):
            try container.encode("html", forKey: .type)
            try container.encode(html, forKey: .html)
        case .markdown(let text):
            try container.encode("markdown", forKey: .type)
            try container.encode(text, forKey: .text)
        case .latex(let text):
            try container.encode("latex", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let image):
            try container.encode("image", forKey: .type)
            try container.encode(image.mimeType, forKey: .mime)
            try container.encode(image.base64, forKey: .data)
            try container.encodeIfPresent(image.width, forKey: .width)
            try container.encodeIfPresent(image.height, forKey: .height)
            try container.encodeIfPresent(image.background, forKey: .background)
        case .omittedImage(let mimeType, let size):
            try container.encode("omitted", forKey: .type)
            try container.encode(mimeType, forKey: .mime)
            try container.encode(size, forKey: .size)
        case .error(let text):
            try container.encode("error", forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }
}
