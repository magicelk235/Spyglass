import Foundation

/// A decoded bencode value, BitTorrent's serialization (BEP 3).
public enum BencodeValue: Equatable, Sendable {
    case integer(Int64)
    /// Raw bytes; text in torrents is usually, but not always, UTF-8.
    case bytes(Data)
    case list([BencodeValue])
    /// Entries in file order. Keys should be sorted, but writers don't all
    /// sort them, so the order is kept as found.
    case dictionary([BencodeEntry])

    /// The value for `key` when this is a dictionary.
    public subscript(key: String) -> BencodeValue? {
        guard case .dictionary(let entries) = self else { return nil }
        let key = Data(key.utf8)
        return entries.first { $0.key == key }?.value
    }

    /// The entry for `key`, with its byte range, when this is a dictionary.
    public func entry(_ key: String) -> BencodeEntry? {
        guard case .dictionary(let entries) = self else { return nil }
        let key = Data(key.utf8)
        return entries.first { $0.key == key }
    }

    public var integer: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var bytes: Data? {
        if case .bytes(let value) = self { return value }
        return nil
    }

    /// The bytes as text, when they are valid UTF-8.
    public var text: String? {
        guard case .bytes(let value) = self else { return nil }
        return String(data: value, encoding: .utf8)
    }

    public var list: [BencodeValue]? {
        if case .list(let items) = self { return items }
        return nil
    }
}

public struct BencodeEntry: Equatable, Sendable {
    public var key: Data
    public var value: BencodeValue
    /// Where the value's encoding sits in the decoded data, counted from its
    /// first byte. A torrent's info hash is taken over exactly these bytes.
    public var range: Range<Int>
}

public enum BencodeError: Error, Equatable {
    case unexpectedEnd
    case invalidInteger(offset: Int)
    case invalidLength(offset: Int)
    /// A dictionary key that isn't a byte string.
    case invalidKey(offset: Int)
    case duplicateKey(offset: Int)
    case unexpectedByte(offset: Int)
    /// More bytes follow the one top-level value.
    case trailingData(offset: Int)
    case tooDeep
    case tooManyValues
    case tooLarge
}

/// Strict bencode decoder: integers without leading zeros or "-0", byte
/// strings whose length fits the input, string keys, no duplicate keys, and
/// nothing after the top-level value. Offsets in errors and ranges count
/// from the first byte of the data passed in.
public enum Bencode {

    public struct Limits: Sendable {
        /// Largest input accepted at all.
        public var maxSize: Int
        /// Lists and dictionaries nested deeper than this are refused, which
        /// also bounds the decoder's recursion.
        public var maxDepth: Int
        /// Values of any kind; bounds memory for input made of tiny values.
        public var maxValues: Int

        public init(maxSize: Int = 32 * 1024 * 1024, maxDepth: Int = 128, maxValues: Int = 1_000_000) {
            self.maxSize = maxSize
            self.maxDepth = maxDepth
            self.maxValues = maxValues
        }

        public static let standard = Limits()
    }

    public static func decode(_ data: Data, limits: Limits = .standard) throws -> BencodeValue {
        guard data.count <= limits.maxSize else { throw BencodeError.tooLarge }
        // Rebase so byte strings slice from a zero-based buffer.
        let source = data.startIndex == 0 ? data : Data(data)
        return try source.withUnsafeBytes { raw in
            var decoder = Decoder(bytes: raw.bindMemory(to: UInt8.self), source: source, limits: limits)
            let value = try decoder.value(depth: 0)
            guard decoder.offset == decoder.bytes.count else {
                throw BencodeError.trailingData(offset: decoder.offset)
            }
            return value
        }
    }

    private struct Decoder {
        let bytes: UnsafeBufferPointer<UInt8>
        /// Byte strings are slices of this, so large ones share its storage.
        let source: Data
        let limits: Limits
        var offset = 0
        var valueCount = 0

        init(bytes: UnsafeBufferPointer<UInt8>, source: Data, limits: Limits) {
            self.bytes = bytes
            self.source = source
            self.limits = limits
        }

        private static let i = UInt8(ascii: "i"), l = UInt8(ascii: "l"), d = UInt8(ascii: "d")
        private static let e = UInt8(ascii: "e"), colon = UInt8(ascii: ":"), minus = UInt8(ascii: "-")
        private static let zero = UInt8(ascii: "0"), nine = UInt8(ascii: "9")

        private static func isDigit(_ byte: UInt8) -> Bool { byte >= zero && byte <= nine }

        private func peek() throws -> UInt8 {
            guard offset < bytes.count else { throw BencodeError.unexpectedEnd }
            return bytes[offset]
        }

        /// `depth` is the number of lists and dictionaries around the value.
        mutating func value(depth: Int) throws -> BencodeValue {
            valueCount += 1
            guard valueCount <= limits.maxValues else { throw BencodeError.tooManyValues }
            let byte = try peek()
            switch byte {
            case Self.i:
                return .integer(try integer())
            case Self.l:
                guard depth < limits.maxDepth else { throw BencodeError.tooDeep }
                offset += 1
                var items: [BencodeValue] = []
                while try peek() != Self.e {
                    items.append(try value(depth: depth + 1))
                }
                offset += 1
                return .list(items)
            case Self.d:
                guard depth < limits.maxDepth else { throw BencodeError.tooDeep }
                offset += 1
                return .dictionary(try entries(depth: depth + 1))
            case Self.zero...Self.nine:
                return .bytes(try byteString())
            default:
                throw BencodeError.unexpectedByte(offset: offset)
            }
        }

        private mutating func entries(depth: Int) throws -> [BencodeEntry] {
            var entries: [BencodeEntry] = []
            // Sorted keys can't repeat, so a set is only built once a key
            // arrives out of order.
            var seen: Set<Data>?
            while try peek() != Self.e {
                let keyOffset = offset
                guard Self.isDigit(bytes[offset]) else { throw BencodeError.invalidKey(offset: keyOffset) }
                let key = try byteString()
                if seen == nil, let last = entries.last?.key, !last.lexicographicallyPrecedes(key) {
                    seen = Set(entries.map(\.key))
                }
                if seen != nil {
                    guard seen!.insert(key).inserted else { throw BencodeError.duplicateKey(offset: keyOffset) }
                }
                let start = offset
                let value = try value(depth: depth)
                entries.append(BencodeEntry(key: key, value: value, range: start..<offset))
            }
            offset += 1
            return entries
        }

        /// `i<digits>e`, with an optional minus; no leading zeros, no "-0".
        private mutating func integer() throws -> Int64 {
            let start = offset
            offset += 1
            var negative = false
            if try peek() == Self.minus {
                negative = true
                offset += 1
            }
            let digitsStart = offset
            var magnitude: UInt64 = 0
            while try Self.isDigit(peek()) {
                let (times10, overflow1) = magnitude.multipliedReportingOverflow(by: 10)
                let (sum, overflow2) = times10.addingReportingOverflow(UInt64(bytes[offset] - Self.zero))
                guard !overflow1, !overflow2 else { throw BencodeError.invalidInteger(offset: start) }
                magnitude = sum
                offset += 1
            }
            let digits = offset - digitsStart
            guard try peek() == Self.e, digits > 0,
                  bytes[digitsStart] != Self.zero || digits == 1,
                  !(negative && magnitude == 0)
            else { throw BencodeError.invalidInteger(offset: start) }
            offset += 1
            if negative {
                guard magnitude <= UInt64(Int64.max) + 1 else { throw BencodeError.invalidInteger(offset: start) }
                return magnitude == UInt64(Int64.max) + 1 ? .min : -Int64(magnitude)
            }
            guard magnitude <= UInt64(Int64.max) else { throw BencodeError.invalidInteger(offset: start) }
            return Int64(magnitude)
        }

        /// `<length>:<bytes>`; the length has no leading zeros and must fit
        /// in what's left of the input.
        private mutating func byteString() throws -> Data {
            let start = offset
            var length = 0
            while offset < bytes.count, Self.isDigit(bytes[offset]) {
                let (times10, overflow1) = length.multipliedReportingOverflow(by: 10)
                let (sum, overflow2) = times10.addingReportingOverflow(Int(bytes[offset] - Self.zero))
                guard !overflow1, !overflow2 else { throw BencodeError.invalidLength(offset: start) }
                length = sum
                offset += 1
            }
            let digits = offset - start
            guard offset < bytes.count, bytes[offset] == Self.colon,
                  bytes[start] != Self.zero || digits == 1
            else { throw BencodeError.invalidLength(offset: start) }
            offset += 1
            guard length <= bytes.count - offset else { throw BencodeError.invalidLength(offset: start) }
            let value = source[offset..<(offset + length)]
            offset += length
            return value
        }
    }
}
