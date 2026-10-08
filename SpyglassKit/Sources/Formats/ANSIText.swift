import Foundation

/// Terminal output with its escape sequences worked out. SGR codes (colors,
/// bold, faint, italic, underline) become styled runs; every other escape
/// sequence, and every control character besides tab and newline, is
/// dropped. A carriage return starts its line over, the way a progress bar
/// redraws itself.
public struct ANSIText: Equatable, Sendable {

    public enum Color: Equatable, Sendable {
        /// One of the 16 colors the page themes: 0–7 standard, 8–15 bright.
        case palette(Int)
        case rgb(UInt8, UInt8, UInt8)
    }

    public struct Style: Equatable, Sendable {
        public var foreground: Color?
        public var background: Color?
        public var bold: Bool
        public var faint: Bool
        public var italic: Bool
        public var underline: Bool

        public init(foreground: Color? = nil, background: Color? = nil, bold: Bool = false,
                    faint: Bool = false, italic: Bool = false, underline: Bool = false) {
            self.foreground = foreground
            self.background = background
            self.bold = bold
            self.faint = faint
            self.italic = italic
            self.underline = underline
        }
    }

    public struct Run: Equatable, Sendable {
        public var text: String
        public var style: Style

        public init(text: String, style: Style) {
            self.text = text
            self.style = style
        }
    }

    public private(set) var runs: [Run]

    /// The text without its styling.
    public var string: String { runs.map(\.text).joined() }

    /// Past `maxRuns - 1` runs the rest of the text is one plain run, so output
    /// that changes color on every character can't turn into millions of runs.
    public init(_ text: String, maxRuns: Int = 20_000) {
        var parser = Parser(maxRuns: max(1, maxRuns))
        var text = text
        text.withUTF8 { parser.parse($0) }
        runs = parser.finish()
    }
}

extension ANSIText {

    private struct Parser {
        let maxRuns: Int
        var runs: [Run] = []
        /// Text of the run being built, in `bufferStyle`.
        var buffer: [UInt8] = []
        var bufferStyle = Style()
        /// The style SGR codes have set so far.
        var style = Style()
        /// Once set, styles are no longer tracked and the rest of the text
        /// collects in `buffer` as the last, plain run.
        var capped: Bool

        init(maxRuns: Int) {
            self.maxRuns = maxRuns
            capped = maxRuns <= 1
        }

        mutating func finish() -> [Run] {
            flush()
            return runs
        }

        mutating func parse(_ bytes: UnsafeBufferPointer<UInt8>) {
            let count = bytes.count
            var index = 0
            var textStart = 0
            while index < count {
                let byte = bytes[index]
                if byte >= 0x20 && byte != 0x7F || byte == 0x0A || byte == 0x09 {
                    index += 1
                    continue
                }
                append(UnsafeBufferPointer(rebasing: bytes[textStart..<index]))
                switch byte {
                case 0x1B:
                    index = skipEscape(bytes, at: index)
                case 0x0D:
                    var next = index + 1
                    while next < count, bytes[next] == 0x0D { next += 1 }
                    // Before a newline, or at the very end, it changes nothing.
                    if next < count, bytes[next] != 0x0A { clearLine() }
                    index = next
                default:
                    index += 1
                }
                textStart = index
            }
            append(UnsafeBufferPointer(rebasing: bytes[textStart..<count]))
        }

        private mutating func append(_ text: UnsafeBufferPointer<UInt8>) {
            guard !text.isEmpty else { return }
            if !capped, style != bufferStyle {
                flush()
                bufferStyle = capped ? Style() : style
            }
            buffer.append(contentsOf: text)
        }

        private mutating func flush() {
            guard !buffer.isEmpty else { return }
            let text = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            if let last = runs.indices.last, runs[last].style == bufferStyle {
                runs[last].text += text
            } else {
                runs.append(Run(text: text, style: bufferStyle))
                if runs.count >= maxRuns - 1 { capped = true }
            }
        }

        /// Drops what's been written since the last newline. The style stays.
        private mutating func clearLine() {
            if let newline = buffer.lastIndex(of: 0x0A) {
                buffer.removeSubrange((newline + 1)...)
                return
            }
            buffer.removeAll(keepingCapacity: true)
            while var last = runs.popLast() {
                if let newline = last.text.utf8.lastIndex(of: 0x0A) {
                    last.text = String(last.text[...newline])
                    runs.append(last)
                    return
                }
            }
        }

        /// Handles the escape sequence starting at `start` (an ESC byte) and
        /// returns the index just past it. Only SGR has an effect.
        private mutating func skipEscape(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int) -> Int {
            let count = bytes.count
            guard start + 1 < count else { return count }
            switch bytes[start + 1] {
            case UInt8(ascii: "["):
                // CSI: parameter bytes, intermediate bytes, one final byte.
                var index = start + 2
                while index < count, (0x30...0x3F).contains(bytes[index]) { index += 1 }
                let parameters = start + 2..<index
                while index < count, (0x20...0x2F).contains(bytes[index]) { index += 1 }
                guard index < count else { return count }
                let final = bytes[index]
                // Anything else breaks the sequence off; that byte is text again.
                guard (0x40...0x7E).contains(final) else { return index }
                if final == UInt8(ascii: "m"), index == parameters.upperBound, !capped {
                    applySGR(UnsafeBufferPointer(rebasing: bytes[parameters]))
                }
                return index + 1
            case UInt8(ascii: "]"):
                // OSC (titles, hyperlinks): up to BEL or ESC \.
                var index = start + 2
                while index < count {
                    if bytes[index] == 0x07 { return index + 1 }
                    if bytes[index] == 0x1B, index + 1 < count, bytes[index + 1] == UInt8(ascii: "\\") { return index + 2 }
                    index += 1
                }
                return count
            case 0x20...0x2F:
                // Intermediate bytes then a final byte, e.g. ESC ( B.
                var index = start + 1
                while index < count, (0x20...0x2F).contains(bytes[index]) { index += 1 }
                return min(count, index + 1)
            case 0x30...0x7E:
                // Two-byte sequences such as ESC 7.
                return start + 2
            default:
                // A lone ESC; whatever follows is text.
                return start + 1
            }
        }

        private mutating func applySGR(_ parameterBytes: UnsafeBufferPointer<UInt8>) {
            // Private-use parameters ("<", "=", ">", "?") aren't SGR.
            guard !parameterBytes.contains(where: { $0 >= 0x3C }) else { return }
            var parameters: [Int?] = []
            var value: Int? = 0
            for byte in parameterBytes {
                if byte == UInt8(ascii: ";") || byte == UInt8(ascii: ":") {
                    parameters.append(value)
                    value = 0
                } else if let current = value {
                    let next = current * 10 + Int(byte - UInt8(ascii: "0"))
                    // Absurdly long numbers are unknown codes, not overflows.
                    value = next <= 1_000_000 ? next : nil
                }
            }
            parameters.append(value)

            var index = 0
            while index < parameters.count {
                let code = parameters[index]
                index += 1
                switch code {
                case 0: style = Style()
                case 1: style.bold = true
                case 2: style.faint = true
                case 3: style.italic = true
                case 4: style.underline = true
                case 22:
                    style.bold = false
                    style.faint = false
                case 23: style.italic = false
                case 24: style.underline = false
                case let code? where (30...37).contains(code): style.foreground = .palette(code - 30)
                case 39: style.foreground = nil
                case let code? where (40...47).contains(code): style.background = .palette(code - 40)
                case 49: style.background = nil
                case let code? where (90...97).contains(code): style.foreground = .palette(code - 90 + 8)
                case let code? where (100...107).contains(code): style.background = .palette(code - 100 + 8)
                case 38, 48:
                    switch Self.extendedColor(parameters, at: &index) {
                    case .color(let color):
                        if code == 38 { style.foreground = color } else { style.background = color }
                    case .ignored:
                        break
                    case .unreadable:
                        // How many parameters the color takes is unknown, so
                        // nothing after it can be read reliably.
                        return
                    }
                default:
                    break
                }
            }
        }

        private enum ExtendedColor {
            case color(Color)
            case ignored
            case unreadable
        }

        /// The color after a 38 or 48: "5;n" from the 256-color palette, or
        /// "2;r;g;b". `index` moves past the parameters it takes.
        private static func extendedColor(_ parameters: [Int?], at index: inout Int) -> ExtendedColor {
            guard index < parameters.count else { return .ignored }
            let mode = parameters[index]
            index += 1
            switch mode {
            case 5:
                guard index < parameters.count else { return .ignored }
                let number = parameters[index]
                index += 1
                guard let number, (0...255).contains(number) else { return .ignored }
                return .color(paletteColor(number))
            case 2:
                let channels = parameters[index..<min(parameters.count, index + 3)]
                index += channels.count
                let values = channels.compactMap { $0 }.filter { (0...255).contains($0) }
                guard values.count == 3 else { return .ignored }
                return .color(.rgb(UInt8(values[0]), UInt8(values[1]), UInt8(values[2])))
            default:
                return .unreadable
            }
        }

        /// xterm's 256 colors: the 16 themed ones, a 6×6×6 cube, then 24 grays.
        private static func paletteColor(_ number: Int) -> Color {
            switch number {
            case 0..<16:
                return .palette(number)
            case 16..<232:
                let cube = number - 16
                func level(_ step: Int) -> UInt8 { step == 0 ? 0 : UInt8(55 + 40 * step) }
                return .rgb(level(cube / 36), level(cube / 6 % 6), level(cube % 6))
            default:
                let gray = UInt8(8 + 10 * (number - 232))
                return .rgb(gray, gray, gray)
            }
        }
    }
}

// The web page gets each run as {"text", "fg", "bg", "bold", "faint",
// "italic", "underline"}, leaving out what's unset. A themed color is its
// palette index; any other is "#rrggbb".
extension ANSIText: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(runs)
    }
}

extension ANSIText.Run: Encodable {
    private enum CodingKeys: String, CodingKey {
        case text, fg, bg, bold, faint, italic, underline
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(style.foreground, forKey: .fg)
        try container.encodeIfPresent(style.background, forKey: .bg)
        if style.bold { try container.encode(true, forKey: .bold) }
        if style.faint { try container.encode(true, forKey: .faint) }
        if style.italic { try container.encode(true, forKey: .italic) }
        if style.underline { try container.encode(true, forKey: .underline) }
    }
}

extension ANSIText.Color: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .palette(let index):
            try container.encode(index)
        case .rgb(let red, let green, let blue):
            try container.encode(String(format: "#%02x%02x%02x", red, green, blue))
        }
    }
}
