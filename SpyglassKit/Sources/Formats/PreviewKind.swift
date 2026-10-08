import Foundation

/// A family of formats the user can switch off as a unit in Settings.
public enum FormatGroup: String, CaseIterable, Codable, Sendable {
    case markdown, notebook, code, structured, diff, table, sqlite, archive, bundle, binary, folder

    public var displayName: String {
        switch self {
        case .markdown:   return "Markdown"
        case .notebook:   return "Jupyter notebooks"
        case .code:       return "Source code"
        case .structured: return "JSON, XML, plist, YAML, TOML"
        case .diff:       return "Diffs and patches"
        case .table:      return "TSV and JSON Lines tables"
        case .sqlite:     return "SQLite databases"
        case .archive:    return "Archives, ISO images, torrents"
        case .bundle:     return "Apps, frameworks, installers, disk images"
        case .binary:     return "Executables and libraries"
        case .folder:     return "Folders"
        }
    }
}

public enum StructuredFormat: String, Sendable { case json, xml, plist, yaml, toml }
public enum ArchiveFormat: String, Sendable { case zip, tar, gzip, bzip2, xz, iso }
public enum BundleFormat: String, Sendable { case app, framework, ipa, pkg, dmg }

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
    case notebook
    /// One JSON value per line (`.jsonl`, `.ndjson`).
    case jsonLines
    case torrent
    /// Mach-O executables, dylibs, object files, static libraries, and
    /// extensionless executables (which may turn out to be scripts).
    case binary
    case folder

    public var group: FormatGroup? {
        switch self {
        case .googleStub, .webloc: return nil
        case .markdown:            return .markdown
        case .notebook:            return .notebook
        case .code:                return .code
        case .structured:          return .structured
        case .diff:                return .diff
        case .table, .jsonLines:   return .table
        case .sqlite:              return .sqlite
        case .archive, .torrent:   return .archive
        case .bundle:              return .bundle
        case .binary:              return .binary
        case .folder:              return .folder
        }
    }

    /// nil means Spyglass has no rich preview for the file; the caller falls
    /// back to plain text or a file card.
    public static func route(filename: String, uti: String?) -> PreviewKind? {
        // A folder's name says nothing about its contents ("notes.md/").
        if uti == "public.folder" { return .folder }
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
        "jar": .archive(.zip), "war": .archive(.zip), "ear": .archive(.zip),
        "apk": .archive(.zip), "aab": .archive(.zip), "whl": .archive(.zip),
        "nupkg": .archive(.zip), "vsix": .archive(.zip), "xpi": .archive(.zip),
        "tar": .archive(.tar),
        "gz": .archive(.gzip), "tgz": .archive(.gzip),
        "bz2": .archive(.bzip2), "tbz": .archive(.bzip2), "tbz2": .archive(.bzip2),
        "xz": .archive(.xz), "txz": .archive(.xz),
        "iso": .archive(.iso),
        "app": .bundle(.app), "framework": .bundle(.framework),
        "ipa": .bundle(.ipa), "pkg": .bundle(.pkg), "dmg": .bundle(.dmg),
        "ipynb": .notebook,
        "jsonl": .jsonLines, "ndjson": .jsonLines,
        "torrent": .torrent,
        "mobileconfig": .structured(.plist),
        "dylib": .binary, "so": .binary, "o": .binary, "a": .binary,
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
        "com.apple.framework": .bundle(.framework),
        "public.make-source": .code(language: "makefile"),
        "com.apple.log": .code(language: "accesslog"),
        "com.spyglass.ipynb": .notebook,
        "public.ndjson": .jsonLines,
        "com.spyglass.jsonl": .jsonLines,
        "org.tukaani.xz-archive": .archive(.xz),
        "org.tukaani.tar-xz-archive": .archive(.xz),
        "com.sun.java-archive": .archive(.zip),
        "com.sun.web-application-archive": .archive(.zip),
        "com.spyglass.ear": .archive(.zip),
        "public.archive.apk": .archive(.zip),
        "com.spyglass.aab": .archive(.zip),
        "com.spyglass.whl": .archive(.zip),
        "com.spyglass.nupkg": .archive(.zip),
        "com.spyglass.vsix": .archive(.zip),
        "com.spyglass.xpi": .archive(.zip),
        "public.iso-image": .archive(.iso),
        "com.looq.iso": .archive(.iso),
        "com.spyglass.torrent": .torrent,
        "com.looq.torrent": .torrent,
        "com.apple.mobileconfig": .structured(.plist),
        "public.unix-executable": .binary,
        "com.apple.mach-o-dylib": .binary,
        "public.object-code": .binary,
        "com.spyglass.shared-object": .binary,
        "com.spyglass.static-library": .binary,
    ]
}
