import Foundation

/// A family of formats the user can switch off as a unit in Settings.
public enum FormatGroup: String, CaseIterable, Codable, Sendable {
    case markdown, code, structured, diff, table, sqlite, archive, bundle

    public var displayName: String {
        switch self {
        case .markdown:   return "Markdown"
        case .code:       return "Source code"
        case .structured: return "JSON, XML, plist, YAML, TOML"
        case .diff:       return "Diffs and patches"
        case .table:      return "TSV tables"
        case .sqlite:     return "SQLite databases"
        case .archive:    return "Archives"
        case .bundle:     return "Apps, installers, disk images"
        }
    }
}

public enum StructuredFormat: String, Sendable { case json, xml, plist, yaml, toml }
public enum ArchiveFormat: String, Sendable { case zip, tar, gzip, bzip2 }
public enum BundleFormat: String, Sendable { case app, ipa, pkg, dmg }

/// What kind of preview a file gets. Routing is by filename first and UTI
/// second, so a file always lands on the same renderer whichever exact UTI
/// LaunchServices assigned it.
public enum PreviewKind: Equatable, Sendable {
    case googleStub
    case webloc
    case markdown
    /// highlight.js language id; nil asks the renderer to auto-detect.
    case code(language: String?)
    case structured(StructuredFormat)
    case diff
    case table(separator: Character)
    case sqlite
    case archive(ArchiveFormat)
    case bundle(BundleFormat)

    public var group: FormatGroup? {
        switch self {
        case .googleStub, .webloc: return nil
        case .markdown:            return .markdown
        case .code:                return .code
        case .structured:          return .structured
        case .diff:                return .diff
        case .table:               return .table
        case .sqlite:              return .sqlite
        case .archive:             return .archive
        case .bundle:              return .bundle
        }
    }

    /// nil means Spyglass has no rich preview for the file; the caller falls
    /// back to plain text or a file card.
    public static func route(filename: String, uti: String?) -> PreviewKind? {
        if let kind = route(filename: filename) { return kind }
        guard let uti else { return nil }
        if let kind = byUTI[uti] { return kind }
        if let language = codeUTIs[uti] { return .code(language: language) }
        if WorkspaceType.allCases.contains(where: { $0.uti == uti }) { return .googleStub }
        return nil
    }

    private static func route(filename: String) -> PreviewKind? {
        let name = filename.lowercased()
        let ext = (name as NSString).pathExtension
        if WorkspaceType(fileExtension: ext) != nil { return .googleStub }
        if let kind = byExtension[ext] { return kind }
        if let lang = CodeLanguage.language(forFilename: name) { return .code(language: lang) }
        return nil
    }

    static let byExtension: [String: PreviewKind] = [
        "webloc": .webloc,
        "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mkd": .markdown,
        "mkdn": .markdown, "mdx": .markdown,
        "json": .structured(.json), "geojson": .structured(.json), "jsonc": .structured(.json),
        "xml": .structured(.xml), "xsd": .structured(.xml), "xsl": .structured(.xml),
        "plist": .structured(.plist),
        "yaml": .structured(.yaml), "yml": .structured(.yaml),
        "toml": .structured(.toml),
        "diff": .diff, "patch": .diff,
        "tsv": .table(separator: "\t"),
        "sqlite": .sqlite, "sqlite3": .sqlite, "db": .sqlite, "db3": .sqlite,
        "zip": .archive(.zip),
        "tar": .archive(.tar),
        "gz": .archive(.gzip), "tgz": .archive(.gzip),
        "bz2": .archive(.bzip2), "tbz": .archive(.bzip2), "tbz2": .archive(.bzip2),
        "app": .bundle(.app), "ipa": .bundle(.ipa), "pkg": .bundle(.pkg), "dmg": .bundle(.dmg),
    ]

    /// Exact non-code UTIs Spyglass claims in `Preview/Info.plist`, for files
    /// the filename table can't place (e.g. a renamed file). Code UTIs live in
    /// `codeUTIs`.
    static let byUTI: [String: PreviewKind] = [
        "com.apple.web-internet-location": .webloc,
        "net.daringfireball.markdown": .markdown,
        "public.markdown": .markdown,
        "com.spyglass.markdown": .markdown,
        "com.looq.mkd": .markdown,
        "net.ia.markdown": .markdown,
        "io.typora.markdown": .markdown,
        "com.unknown.md": .markdown,
        "com.looq.markdown": .markdown,
        "com.looq.mdx": .markdown,
        "com.spyglass.mdx": .markdown,
        "public.json": .structured(.json),
        "com.looq.json": .structured(.json),
        "public.geojson": .structured(.json),
        "com.spyglass.jsonc": .structured(.json),
        "public.xml": .structured(.xml),
        "com.looq.xml": .structured(.xml),
        "com.spyglass.xml": .structured(.xml),
        "com.apple.property-list": .structured(.plist),
        "com.apple.xml-property-list": .structured(.plist),
        "com.apple.binary-property-list": .structured(.plist),
        "com.apple.ascii-property-list": .structured(.plist),
        "public.yaml": .structured(.yaml),
        "com.looq.yaml": .structured(.yaml),
        "public.toml": .structured(.toml),
        "io.toml": .structured(.toml),
        "com.looq.toml-mirror": .structured(.toml),
        "public.patch-file": .diff,
        "com.looq.patch": .diff,
        "public.tab-separated-values-text": .table(separator: "\t"),
        "com.looq.tsv": .table(separator: "\t"),
        "org.sqlite.database": .sqlite,
        "com.looq.sqlite": .sqlite,
        "com.spyglass.sqlite": .sqlite,
        "public.zip-archive": .archive(.zip),
        "com.pkware.zip-archive": .archive(.zip),
        "public.tar-archive": .archive(.tar),
        "org.gnu.gnu-zip-archive": .archive(.gzip),
        "org.gnu.gnu-zip-tar-archive": .archive(.gzip),
        "public.bzip2-archive": .archive(.bzip2),
        "public.tar-bzip2-archive": .archive(.bzip2),
        "com.apple.application-bundle": .bundle(.app),
        "com.apple.itunes.ipa": .bundle(.ipa),
        "com.looq.ipa": .bundle(.ipa),
        "com.apple.installer-package-archive": .bundle(.pkg),
        "com.apple.disk-image-udif": .bundle(.dmg),
        "public.make-source": .code(language: "makefile"),
        "com.apple.log": .code(language: "accesslog"),
    ]
}
