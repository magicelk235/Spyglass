import Foundation

/// Decides whether the leading bytes of a file are text, for the plain-text
/// fallback preview.
public enum TextSniffer {

    /// How much of a file the plain-text fallback reads.
    public static let readLimit = 256 * 1024

    /// UTF-8, or UTF-16 with a BOM. A multi-byte sequence cut off by the read
    /// limit is trimmed rather than failing the whole decode. Returns nil for
    /// binary data (a NUL byte, or bytes that aren't valid UTF-8).
    public static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            var body = data
            if body.count % 2 == 1 { body.removeLast() }
            return String(data: body, encoding: .utf16)
        }
        if data.contains(0) { return nil }
        // A UTF-8 character is at most 4 bytes, so at most 3 trailing bytes
        // can belong to a sequence the limit cut in half.
        for trim in 0...min(3, data.count) {
            if let text = String(data: data.dropLast(trim), encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    /// Reads at most `readLimit` bytes and decodes them. `truncated` is true
    /// when the file is longer than what was read.
    public static func readText(at url: URL) -> (text: String, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: readLimit + 1) ?? Data() else { return nil }
        let truncated = data.count > readLimit
        guard let text = decode(truncated ? data.prefix(readLimit) : data) else { return nil }
        return (text, truncated)
    }
}
