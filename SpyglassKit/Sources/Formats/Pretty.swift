import Foundation
import Security

public enum PrettyError: Error, Equatable {
    case malformed(String)
    /// Formatting would produce far more text than the preview can show.
    case tooLarge
}

/// Text a formatter produced, cut at a line boundary when it reached the output limit.
public struct PrettyText: Equatable, Sendable {
    public var text: String
    public var isCut: Bool

    public init(text: String, isCut: Bool) {
        self.text = text
        self.isCut = isCut
    }
}

/// A property list that came wrapped in CMS signed data, as configuration
/// profiles usually are.
public struct SignedPropertyList: Equatable, Sendable {
    /// The property list as XML text.
    public var text: PrettyText
    /// Common name of the signing certificate, when it has one.
    public var signer: String?

    public init(text: PrettyText, signer: String?) {
        self.text = text
        self.signer = signer
    }
}

/// Re-indents machine-written JSON and XML for the structured-text preview.
public enum Pretty {

    /// Re-indents JSON token by token (2 spaces): key order, number spelling and string escapes are kept byte for byte.
    ///
    /// Several whitespace-separated top-level values (JSON Lines) are allowed;
    /// each starts on its own line. With `allowTruncatedEnd`, input that simply
    /// stops part-way is formatted up to where it stops instead of throwing.
    /// `outputLimit` is in UTF-8 bytes: past it nothing more is emitted, but the
    /// rest of the input is still checked so malformed text always throws.
    public static func json(_ text: String, allowTruncatedEnd: Bool = false, outputLimit: Int = .max) throws -> PrettyText {
        var text = text
        return try text.withUTF8 { bytes in
            var printer = JSONPrinter(bytes: bytes, allowTruncatedEnd: allowTruncatedEnd, limit: max(0, outputLimit))
            try printer.run()
            return PrettyText(text: String(decoding: printer.out, as: UTF8.self), isCut: printer.isCut)
        }
    }

    /// Re-indents XML through XMLDocument with .nodePrettyPrint, keeping the declaration.
    ///
    /// External entities and DTDs are never fetched. Throws `.tooLarge` when a
    /// quick scan shows the indentation alone would exceed `outputLimit`, which
    /// happens with deeply nested documents.
    public static func xml(_ text: String, outputLimit: Int = .max) throws -> PrettyText {
        let limit = max(0, outputLimit)
        let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        if estimatedXMLIndentation(source, giveUpAbove: limit) > limit {
            throw PrettyError.tooLarge
        }

        let options: XMLNode.Options = [
            .nodeLoadExternalEntitiesNever,
            .nodePreserveCDATA,
            .nodePreserveAttributeOrder,
            .nodePreserveNamespaceOrder,
            .nodePreserveEmptyElements,
        ]
        let document: XMLDocument
        do {
            document = try XMLDocument(xmlString: source, options: options)
        } catch {
            throw PrettyError.malformed(error.localizedDescription)
        }
        var output = document.xmlString(options: [.nodePrettyPrint, .nodeCompactEmptyElement])

        // XMLDocument always writes its own declaration, sometimes with
        // attributes the file never had (standalone="yes" next to a DOCTYPE).
        // Swap it for the original, or drop it if there wasn't one.
        if output.hasPrefix("<?xml"), let end = output.range(of: "?>") {
            var rest = output[end.upperBound...]
            if rest.first == "\n" { rest = rest.dropFirst() }
            output = String(rest)
        }
        // It also follows a one-line DOCTYPE with a blank line.
        if output.hasPrefix("<!DOCTYPE"), let lineEnd = output.firstIndex(of: "\n"),
           output[..<lineEnd].hasSuffix(">"), output[output.index(after: lineEnd)...].first == "\n" {
            output.remove(at: lineEnd)
        }
        if let declaration = xmlDeclaration(in: source) {
            output = declaration + "\n" + output
        }

        let bytes = Array(output.utf8)
        guard bytes.count > limit else { return PrettyText(text: output, isCut: false) }
        let kept = cutAtLineBoundary(bytes, limit: limit)
        return PrettyText(text: String(decoding: bytes[..<kept], as: UTF8.self), isCut: true)
    }

    /// Property list data (binary, XML or OpenStep) as XML plist text.
    ///
    /// A binary plist can point at the same array or dictionary from many
    /// places, so a few kilobytes can stand for an exponentially larger XML
    /// document. Throws `.tooLarge` when the XML would pass `outputLimit` bytes.
    public static func xmlPropertyList(from data: Data, outputLimit: Int = 8 << 20) throws -> String {
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw PrettyError.malformed("not a property list")
        }
        if estimatedXMLPropertyListSize(plist, giveUpAbove: outputLimit) > outputLimit {
            throw PrettyError.tooLarge
        }
        guard
            let xmlData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
            let xml = String(data: xmlData, encoding: .utf8)
        else { throw PrettyError.malformed("property list can't be written as XML") }
        guard xmlData.count <= outputLimit else { throw PrettyError.tooLarge }
        return xml
    }

    /// Unwraps CMS (PKCS #7) signed data and formats the property list inside
    /// for display. XML is always re-indented, since whatever signed it
    /// wrote it by machine; binary becomes XML; OpenStep text stays as is.
    ///
    /// Returns nil when `data` isn't signed data with its content embedded,
    /// which includes every unsigned property list. Throws when the signed
    /// content isn't a property list. The signature is not checked.
    public static func signedPropertyList(_ data: Data, outputLimit: Int = 8 << 20) throws -> SignedPropertyList? {
        // DER signed data starts with a SEQUENCE; no property list does.
        guard data.first == 0x30 else { return nil }
        var created: CMSDecoder?
        guard CMSDecoderCreate(&created) == errSecSuccess, let decoder = created else { return nil }
        let updated = data.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
        var content: CFData?
        guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
              CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return nil }
        let inner = content as Data

        guard (try? PropertyListSerialization.propertyList(from: inner, format: nil)) != nil else {
            throw PrettyError.malformed("the signed content isn't a property list")
        }
        let text: PrettyText
        if inner.starts(with: Array("bplist".utf8)) {
            text = PrettyText(text: try xmlPropertyList(from: inner, outputLimit: outputLimit), isCut: false)
        } else if let decoded = TextSniffer.decode(inner) {
            let start = decoded.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
            if start.hasPrefix("<"), let formatted = try? xml(decoded, outputLimit: outputLimit) {
                text = formatted
            } else {
                text = PrettyText(text: decoded, isCut: false)
            }
        } else {
            throw PrettyError.malformed("the signed property list isn't text")
        }
        return SignedPropertyList(text: text, signer: signerName(decoder))
    }

    private static func signerName(_ decoder: CMSDecoder) -> String? {
        var signers = 0
        var certificate: SecCertificate?
        guard CMSDecoderGetNumSigners(decoder, &signers) == errSecSuccess, signers > 0,
              CMSDecoderCopySignerCert(decoder, 0, &certificate) == errSecSuccess, let certificate else { return nil }
        var name: CFString?
        if SecCertificateCopyCommonName(certificate, &name) == errSecSuccess, let name, CFStringGetLength(name) > 0 {
            return name as String
        }
        return SecCertificateCopySubjectSummary(certificate) as String?
    }

    /// Roughly how many bytes the XML form of a decoded property list takes:
    /// tags, tab indentation and contents, with shared objects counted every
    /// time they're referenced, as the XML writer repeats them. Walks with an
    /// explicit stack and stops as soon as the total passes `limit`.
    static func estimatedXMLPropertyListSize(_ plist: Any, giveUpAbove limit: Int) -> Int {
        // The XML header and DOCTYPE.
        var total = 200
        var pending: [(node: Any, depth: Int)] = [(plist, 0)]

        func add(_ bytes: Int) -> Bool {
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            total = overflow ? .max : sum
            return total <= limit
        }

        while let entry = pending.popLast() {
            let (node, depth) = entry
            // One tab per level, plus the newline.
            let line = depth + 1
            let fits: Bool
            switch node {
            case let array as NSArray:
                fits = add(2 * line + 15)
                for element in array { pending.append((element, depth + 1)) }
            case let dictionary as NSDictionary:
                fits = add(2 * line + 13)
                for (key, value) in dictionary {
                    let keyLength = (key as? NSString)?.lengthOfBytes(using: String.Encoding.utf8.rawValue) ?? 0
                    guard add(line + 1 + 11 + keyLength) else { return total }
                    pending.append((value, depth + 1))
                }
            case let string as NSString:
                // Escaping "&" and "<" can grow the text; this is an estimate.
                fits = add(line + 17 + string.lengthOfBytes(using: String.Encoding.utf8.rawValue))
            case let bytes as NSData:
                // Base64 is 4/3 the size, wrapped into indented lines.
                fits = add(2 * line + 13 + bytes.length / 3 * 4 + (bytes.length / 36 + 1) * line)
            case is NSDate:
                fits = add(line + 33)
            default:
                // Numbers and booleans.
                fits = add(line + 40)
            }
            if !fits { return total }
        }
        return total
    }

    /// True when text looks machine-written rather than hand-formatted.
    ///
    /// That is: some line is longer than 1000 characters, or the whole document
    /// (ignoring trailing whitespace) sits on one or two lines and is longer
    /// than 80 characters.
    public static func looksMinified(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { bytes in
            var end = bytes.count
            while end > 0, isJSONWhitespace(bytes[end - 1]) { end -= 1 }
            guard end > 0 else { return false }

            var lines = 1
            var lineLength = 0
            var total = 0
            for index in 0..<end {
                let byte = bytes[index]
                // Count characters as Unicode scalars: skip UTF-8 continuation bytes.
                if byte & 0xC0 == 0x80 { continue }
                total += 1
                if byte == 0x0A {
                    lines += 1
                    lineLength = 0
                } else {
                    lineLength += 1
                    if lineLength > 1000 { return true }
                }
            }
            return lines <= 2 && total > 80
        }
    }

    /// What the structured preview shows: formatted when the input looks minified and parses, otherwise the original text. Never throws.
    ///
    /// `truncated` says the text is only the start of the file. Truncated JSON
    /// is still formatted as far as it goes; truncated XML can't be parsed, so
    /// it's shown as is.
    public static func displayText(_ text: String, format: StructuredFormat, truncated: Bool, outputLimit: Int = .max) -> PrettyText {
        let original = PrettyText(text: text, isCut: false)
        switch format {
        case .json:
            guard looksMinified(text) else { return original }
            return (try? json(text, allowTruncatedEnd: truncated, outputLimit: outputLimit)) ?? original
        case .xml:
            return displayXML(text, truncated: truncated, outputLimit: outputLimit) ?? original
        case .plist:
            // Text that doesn't start with "<" is OpenStep, which XMLDocument
            // can't read.
            let start = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
            guard start.hasPrefix("<") else { return original }
            return displayXML(text, truncated: truncated, outputLimit: outputLimit) ?? original
        case .yaml, .toml:
            return original
        }
    }

    // MARK: - XML helpers

    /// XMLDocument's pretty printer indents each level by four spaces.
    static let xmlIndentWidth = 4

    private static func displayXML(_ text: String, truncated: Bool, outputLimit: Int) -> PrettyText? {
        guard !truncated, looksMinified(text) else { return nil }
        return try? xml(text, outputLimit: outputLimit)
    }

    /// The `<?xml …?>` declaration exactly as written, if the document starts with one.
    private static func xmlDeclaration(in text: String) -> String? {
        guard text.hasPrefix("<?xml"), let end = text.range(of: "?>") else { return nil }
        let declaration = text[..<end.upperBound]
        // "<?xml-stylesheet …?>" is a processing instruction, not the declaration.
        let afterName = declaration.dropFirst(5).first
        guard afterName == "?" || afterName?.isWhitespace == true else { return nil }
        return String(declaration)
    }

    /// Roughly how many bytes of indentation the pretty-printed document will
    /// carry: each element's depth times the indent width. Comments, CDATA,
    /// processing instructions and declarations are skipped so a "<" inside
    /// them isn't taken for a tag. Stops counting once past `giveUpAbove`.
    static func estimatedXMLIndentation(_ text: String, giveUpAbove limit: Int) -> Int {
        let commentStart = Array("<!--".utf8), commentEnd = Array("-->".utf8)
        let cdataStart = Array("<![CDATA[".utf8), cdataEnd = Array("]]>".utf8)
        let instructionEnd = Array("?>".utf8)
        var text = text
        return text.withUTF8 { bytes in
            let count = bytes.count
            var index = 0
            var depth = 0
            var total = 0

            func skip(past terminator: [UInt8], from start: Int) -> Int {
                var position = start
                while position < count {
                    if bytes[position] == terminator[0], position + terminator.count <= count {
                        var matches = true
                        for offset in 1..<terminator.count where bytes[position + offset] != terminator[offset] {
                            matches = false
                            break
                        }
                        if matches { return position + terminator.count }
                    }
                    position += 1
                }
                return count
            }

            func startsWith(_ prefix: [UInt8], at position: Int) -> Bool {
                guard position + prefix.count <= count else { return false }
                for offset in 0..<prefix.count where bytes[position + offset] != prefix[offset] {
                    return false
                }
                return true
            }

            while index < count {
                guard bytes[index] == UInt8(ascii: "<") else {
                    index += 1
                    continue
                }
                let next = index + 1 < count ? bytes[index + 1] : 0
                if startsWith(commentStart, at: index) {
                    index = skip(past: commentEnd, from: index + commentStart.count)
                } else if startsWith(cdataStart, at: index) {
                    index = skip(past: cdataEnd, from: index + cdataStart.count)
                } else if next == UInt8(ascii: "?") {
                    index = skip(past: instructionEnd, from: index + 2)
                } else if next == UInt8(ascii: "!") {
                    index = skip(past: [UInt8(ascii: ">")], from: index + 2)
                } else if next == UInt8(ascii: "/") {
                    depth = max(0, depth - 1)
                    index = skip(past: [UInt8(ascii: ">")], from: index + 2)
                } else {
                    let (sum, overflow) = total.addingReportingOverflow(depth * xmlIndentWidth)
                    if overflow || sum > limit { return overflow ? .max : sum }
                    total = sum
                    // Find the end of the tag, stepping over quoted attribute
                    // values that may contain ">".
                    var position = index + 1
                    var quote: UInt8 = 0
                    while position < count {
                        let byte = bytes[position]
                        if quote != 0 {
                            if byte == quote { quote = 0 }
                        } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                            quote = byte
                        } else if byte == UInt8(ascii: ">") {
                            break
                        }
                        position += 1
                    }
                    let selfClosing = position < count && position > index + 1
                        && bytes[position - 1] == UInt8(ascii: "/")
                    if !selfClosing { depth += 1 }
                    index = position + 1
                }
            }
            return total
        }
    }

    /// How many leading bytes to keep so the text ends with the last complete
    /// line that fits in `limit`. The newline itself is dropped.
    static func cutAtLineBoundary(_ bytes: [UInt8], limit: Int) -> Int {
        guard bytes.count > limit else { return bytes.count }
        var index = min(limit, bytes.count - 1)
        while index >= 0 {
            if bytes[index] == 0x0A { return index }
            index -= 1
        }
        return 0
    }

    fileprivate static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}

// MARK: - JSON

/// A single pass over JSON bytes that validates and re-indents at once. An
/// explicit stack of open containers replaces recursion, so nesting depth is
/// limited only by the input size.
private struct JSONPrinter {
    let bytes: UnsafeBufferPointer<UInt8>
    let allowTruncatedEnd: Bool
    let limit: Int

    private(set) var out: [UInt8] = []
    private(set) var isCut = false

    private var index = 0
    /// Open containers, as their opening byte.
    private var stack: [UInt8] = []

    private enum State {
        /// Between top-level values.
        case document
        case afterOpenArray
        case afterOpenObject
        /// After a comma in an array.
        case element
        /// After a comma in an object.
        case key
        case afterKey
        case afterColon
        /// After a complete value inside a container.
        case afterValue
    }

    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")
    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let indentWidth = 2

    init(bytes: UnsafeBufferPointer<UInt8>, allowTruncatedEnd: Bool, limit: Int) {
        self.bytes = bytes
        self.allowTruncatedEnd = allowTruncatedEnd
        self.limit = limit
        // Re-indenting usually grows minified JSON by well under 2x.
        let guess = bytes.count > Int.max / 2 ? bytes.count : bytes.count * 2
        out.reserveCapacity(min(limit, guess) + 1)
    }

    mutating func run() throws {
        let count = bytes.count
        if count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }

        var state = State.document
        var documents = 0
        // A later top-level value has to be separated from the previous one by whitespace.
        var needsSeparator = false

        while index < count {
            let byte = bytes[index]
            if Pretty.isJSONWhitespace(byte) {
                index += 1
                needsSeparator = false
                continue
            }
            switch state {
            case .document:
                if needsSeparator { throw unexpected(byte) }
                if documents > 0 { lineBreak() }
                documents += 1
                guard try value(byte, state: &state) else { return }
            case .afterOpenArray:
                if byte == Self.closeBracket {
                    emit(byte)
                    index += 1
                    closed(&state)
                } else {
                    lineBreak()
                    guard try value(byte, state: &state) else { return }
                }
            case .element:
                lineBreak()
                guard try value(byte, state: &state) else { return }
            case .afterColon:
                // The space goes out with the value so a document cut right
                // after a colon doesn't end in trailing whitespace.
                emit(0x20)
                guard try value(byte, state: &state) else { return }
            case .afterOpenObject, .key:
                if byte == Self.closeBrace, state == .afterOpenObject {
                    emit(byte)
                    index += 1
                    closed(&state)
                } else if byte == Self.quote {
                    lineBreak()
                    guard try string() else { return }
                    state = .afterKey
                } else {
                    throw malformed("expected a quoted key")
                }
            case .afterKey:
                guard byte == UInt8(ascii: ":") else { throw malformed("expected ':' after key") }
                emit(byte)
                index += 1
                state = .afterColon
            case .afterValue:
                let open = stack.last ?? 0
                if byte == UInt8(ascii: ",") {
                    emit(byte)
                    index += 1
                    state = open == Self.openBrace ? .key : .element
                } else if (byte == Self.closeBrace && open == Self.openBrace)
                            || (byte == Self.closeBracket && open == Self.openBracket) {
                    stack.removeLast()
                    lineBreak()
                    emit(byte)
                    index += 1
                    state = stack.isEmpty ? .document : .afterValue
                } else {
                    throw unexpected(byte)
                }
            }
            if state == .document { needsSeparator = true }
        }

        if documents == 0 { throw PrettyError.malformed("no JSON value") }
        if state != .document && !allowTruncatedEnd { throw PrettyError.malformed("unexpected end of input") }
    }

    /// Reads one value starting at `byte`. Returns false when the input ended
    /// inside it and truncation is allowed, meaning formatting is done.
    private mutating func value(_ byte: UInt8, state: inout State) throws -> Bool {
        switch byte {
        case Self.openBrace, Self.openBracket:
            emit(byte)
            stack.append(byte)
            index += 1
            state = byte == Self.openBrace ? .afterOpenObject : .afterOpenArray
            return true
        case Self.quote:
            guard try string() else { return false }
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            guard try number() else { return false }
        case UInt8(ascii: "t"):
            guard try literal("true") else { return false }
        case UInt8(ascii: "f"):
            guard try literal("false") else { return false }
        case UInt8(ascii: "n"):
            guard try literal("null") else { return false }
        default:
            throw unexpected(byte)
        }
        state = stack.isEmpty ? .document : .afterValue
        return true
    }

    /// After an empty container closed.
    private mutating func closed(_ state: inout State) {
        stack.removeLast()
        state = stack.isEmpty ? .document : .afterValue
    }

    // MARK: Tokens

    /// Copies a string token through unchanged after checking its escapes.
    private mutating func string() throws -> Bool {
        let start = index
        let count = bytes.count
        var position = start + 1
        while position < count {
            let byte = bytes[position]
            if byte == Self.quote {
                position += 1
                emit(start, position)
                index = position
                return true
            }
            if byte < 0x20 { throw malformed("control character in string", at: position) }
            if byte == Self.backslash {
                guard position + 1 < count else { break }
                switch bytes[position + 1] {
                case Self.quote, Self.backslash, UInt8(ascii: "/"),
                     UInt8(ascii: "b"), UInt8(ascii: "f"), UInt8(ascii: "n"),
                     UInt8(ascii: "r"), UInt8(ascii: "t"):
                    position += 2
                case UInt8(ascii: "u"):
                    var digit = position + 2
                    while digit < count, digit < position + 6 {
                        guard Self.isHexDigit(bytes[digit]) else {
                            throw malformed("bad \\u escape", at: position)
                        }
                        digit += 1
                    }
                    position = digit
                default:
                    throw malformed("bad escape", at: position)
                }
                continue
            }
            position += 1
        }
        return try endedEarly(from: start, reason: "unterminated string")
    }

    /// `-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?`, copied through as written.
    private mutating func number() throws -> Bool {
        let start = index
        let count = bytes.count
        var position = start

        func digits() -> Int {
            var run = 0
            while position < count, Self.isDigit(bytes[position]) {
                position += 1
                run += 1
            }
            return run
        }

        if bytes[position] == UInt8(ascii: "-") { position += 1 }
        if position == count { return try endedEarly(from: start, reason: "number cut short") }
        if bytes[position] == UInt8(ascii: "0") {
            position += 1
        } else if digits() == 0 {
            throw malformed("bad number", at: start)
        }
        if position < count, bytes[position] == UInt8(ascii: ".") {
            position += 1
            if digits() == 0 {
                if position == count { return try endedEarly(from: start, reason: "number cut short") }
                throw malformed("bad number", at: start)
            }
        }
        if position < count, bytes[position] | 0x20 == UInt8(ascii: "e") {
            position += 1
            if position < count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") {
                position += 1
            }
            if digits() == 0 {
                if position == count { return try endedEarly(from: start, reason: "number cut short") }
                throw malformed("bad number", at: start)
            }
        }
        // "01" or "1.2.3" must not read as two values.
        try requireDelimiter(at: position)
        emit(start, position)
        index = position
        return true
    }

    private mutating func literal(_ word: StaticString) throws -> Bool {
        let start = index
        let count = bytes.count
        let length = word.utf8CodeUnitCount
        let expected = UnsafeBufferPointer(start: word.utf8Start, count: length)
        for offset in 0..<length {
            let position = start + offset
            if position == count { return try endedEarly(from: start, reason: "literal cut short") }
            guard bytes[position] == expected[offset] else { throw malformed("unknown word", at: start) }
        }
        try requireDelimiter(at: start + length)
        emit(start, start + length)
        index = start + length
        return true
    }

    private func requireDelimiter(at position: Int) throws {
        guard position < bytes.count else { return }
        let byte = bytes[position]
        guard Pretty.isJSONWhitespace(byte) || byte == UInt8(ascii: ",")
                || byte == Self.closeBrace || byte == Self.closeBracket
        else { throw malformed("unexpected character after value", at: position) }
    }

    /// The input stopped inside a token: emit what's there when truncation is
    /// allowed, otherwise fail.
    private mutating func endedEarly(from start: Int, reason: String) throws -> Bool {
        guard allowTruncatedEnd else { throw PrettyError.malformed(reason) }
        emit(start, bytes.count)
        index = bytes.count
        return false
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte | 0x20 >= UInt8(ascii: "a") && byte | 0x20 <= UInt8(ascii: "f"))
    }

    // MARK: Output

    /// Starts a new line indented to the current depth. When even the
    /// indentation won't fit, the output so far ends on a complete line, so
    /// that's where it's cut.
    private mutating func lineBreak() {
        guard !isCut else { return }
        let indent = stack.count.multipliedReportingOverflow(by: Self.indentWidth)
        let needed = out.count.addingReportingOverflow(1 + indent.partialValue)
        guard !indent.overflow, !needed.overflow, needed.partialValue <= limit else {
            isCut = true
            return
        }
        out.append(0x0A)
        out.append(contentsOf: repeatElement(0x20, count: indent.partialValue))
    }

    private mutating func emit(_ byte: UInt8) {
        guard !isCut else { return }
        out.append(byte)
        trimIfOverLimit()
    }

    private mutating func emit(_ start: Int, _ end: Int) {
        guard !isCut, start < end else { return }
        out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<end]))
        trimIfOverLimit()
    }

    private mutating func trimIfOverLimit() {
        guard out.count > limit else { return }
        out.removeSubrange(Pretty.cutAtLineBoundary(out, limit: limit)...)
        isCut = true
    }

    // MARK: Errors

    private func unexpected(_ byte: UInt8) -> PrettyError {
        let shown = byte >= 0x21 && byte < 0x7F
            ? "'\(Character(Unicode.Scalar(byte)))'"
            : String(format: "byte 0x%02X", byte)
        return malformed("unexpected \(shown)")
    }

    private func malformed(_ reason: String, at position: Int? = nil) -> PrettyError {
        .malformed("\(reason) at offset \(position ?? index)")
    }
}
