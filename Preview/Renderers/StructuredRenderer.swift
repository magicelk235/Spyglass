import AppKit
import SpyglassKit

/// JSON, XML, property lists, YAML and TOML. Minified JSON and XML are
/// re-indented first; binary property lists are shown as XML, and signed
/// ones (configuration profiles) are unwrapped. Everything then goes
/// through the code view.
struct StructuredRenderer: PreviewRenderer {

    /// Longer text files show their first 2 MB.
    nonisolated static let limit = 2_000_000
    /// Re-indenting can make text several times longer; past this the
    /// formatted text is cut at a line boundary.
    nonisolated static let formattedLimit = 4_000_000
    /// A binary property list can only be decoded whole, so it gets a larger
    /// read limit of its own.
    nonisolated static let binaryPlistLimit = 10_000_000
    /// JSON and XML produce far more highlighted spans per byte than code.
    nonisolated static let highlightLimit = 500_000

    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView {
        guard case .structured(let format) = kind else { throw RenderError.unsupported("not structured text") }
        let (payload, note) = try await Task.detached(priority: .userInitiated) {
            try Self.prepare(url, format: format, settings: settings)
        }.value
        let view = try await WebRenderer.makeView(payload, settings: settings)
        return FallbackViews.withNote(view, note: note)
    }

    nonisolated static func prepare(_ url: URL, format: StructuredFormat,
                                    settings: PreviewSettings) throws -> (WebPayload, String?) {
        var notes: [String?] = []
        var signerNote: String?
        let text: String
        let language: String
        if format == .plist, isBinaryPlist(url) {
            (text, language) = (try binaryPlistXML(url, notes: &notes), "xml")
        } else if format == .plist, let signed = try signedPropertyList(url) {
            signerNote = signed.signer.map { "Profile signed by \($0)" } ?? "Signed profile"
            if signed.text.isCut {
                notes.append("Formatted text cut at \(PreviewNote.size(formattedLimit))")
            }
            text = signed.text.text
            language = Self.language(for: .plist, text: text)
        } else {
            let file = try FilePrefix.read(url, limit: limit)
            notes.append(file.shownPart(limit: limit))
            let shown = Pretty.displayText(file.text, format: format, truncated: file.truncated, outputLimit: formattedLimit)
            if shown.isCut {
                notes.append("Formatted text cut at \(PreviewNote.size(formattedLimit))")
            }
            text = shown.text
            language = Self.language(for: format, text: text)
        }
        let code = WebPayload.code(text, language: language, highlightLimit: highlightLimit, settings: settings)
        var payload = code.payload
        payload.truncated = notes.contains { $0 != nil }
        notes.append(code.note)
        return (payload, PreviewNote.joined([signerNote] + notes))
    }

    nonisolated static func language(for format: StructuredFormat, text: String) -> String {
        switch format {
        case .json: return "json"
        case .xml: return "xml"
        case .yaml: return "yaml"
        case .toml: return "toml"
        case .plist:
            // XML, or the old OpenStep text format, which no grammar covers.
            let start = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
            return start.hasPrefix("<") ? "xml" : "plaintext"
        }
    }

    nonisolated static func isBinaryPlist(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 8)) == Data("bplist00".utf8)
    }

    /// The property list inside CMS signed data, or nil for a file that isn't
    /// signed data.
    nonisolated static func signedPropertyList(_ url: URL) throws -> SignedPropertyList? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard try handle.read(upToCount: 1) == Data([0x30]) else { return nil }
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: binaryPlistLimit + 1) ?? Data()
        guard data.count <= binaryPlistLimit else {
            throw RenderError.unsupported("signed property list over \(PreviewNote.size(binaryPlistLimit))")
        }
        return try Pretty.signedPropertyList(data, outputLimit: formattedLimit)
    }

    nonisolated static func binaryPlistXML(_ url: URL, notes: inout [String?]) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= binaryPlistLimit else {
            throw RenderError.unsupported("binary property list over \(PreviewNote.size(binaryPlistLimit))")
        }
        let xml = try Pretty.xmlPropertyList(from: Data(contentsOf: url), outputLimit: 4 * formattedLimit)
        let utf8 = xml.utf8
        guard utf8.count > formattedLimit else { return xml }
        // Cut after the last full line that fits.
        let end = utf8.index(utf8.startIndex, offsetBy: formattedLimit)
        let cut = utf8[..<end].lastIndex(of: UInt8(ascii: "\n")).map { utf8.index(after: $0) } ?? end
        notes.append("XML cut at \(PreviewNote.size(formattedLimit))")
        return String(decoding: utf8[..<cut], as: UTF8.self)
    }
}
