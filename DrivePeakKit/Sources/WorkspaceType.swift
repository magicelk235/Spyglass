import Foundation

/// The six Google Workspace stub file types DrivePeak previews.
///
/// Single source of truth: filename extension, custom UTI, Google URL path,
/// export capability, and display identity all derive from this enum. Nothing
/// else in the app hardcodes a type list.
public enum WorkspaceType: String, CaseIterable, Sendable {
    case doc      // .gdoc
    case sheet    // .gsheet
    case slides   // .gslides
    case drawing  // .gdraw
    case form     // .gform
    case site     // .gsite

    /// The on-disk filename extension (without the dot).
    public var fileExtension: String {
        switch self {
        case .doc: "gdoc"
        case .sheet: "gsheet"
        case .slides: "gslides"
        case .drawing: "gdraw"
        case .form: "gform"
        case .site: "gsite"
        }
    }

    /// The custom UTI the app declares so Quick Look routes the file to us.
    /// macOS otherwise types these files as an anonymous `dyn.*` UTI.
    public var uti: String { "com.drivepeak.\(rawValue)" }

    public init?(fileExtension ext: String) {
        let normalized = ext.lowercased()
        guard let match = Self.allCases.first(where: { $0.fileExtension == normalized })
        else { return nil }
        self = match
    }

    /// Human-facing product name.
    public var displayName: String {
        switch self {
        case .doc: "Google Docs"
        case .sheet: "Google Sheets"
        case .slides: "Google Slides"
        case .drawing: "Google Drawings"
        case .form: "Google Forms"
        case .site: "Google Sites"
        }
    }

    /// Path segment for the canonical open-in-browser URL.
    /// e.g. `https://docs.google.com/<urlPath>/<doc_id>/edit`
    var urlPath: String {
        switch self {
        case .doc: "document/d"
        case .sheet: "spreadsheets/d"
        case .slides: "presentation/d"
        case .drawing: "drawings/d"
        case .form: "forms/d"
        case .site: "sites/d"
        }
    }

    /// Whether the Drive API can export this type to a renderable file.
    /// Forms and Sites cannot be exported → they stay on the offline card.
    public var isExportable: Bool {
        switch self {
        case .doc, .sheet, .slides, .drawing: true
        case .form, .site: false
        }
    }

    /// SF Symbol used on the offline card.
    public var systemImage: String {
        switch self {
        case .doc: "doc.text"
        case .sheet: "tablecells"
        case .slides: "rectangle.on.rectangle"
        case .drawing: "scribble.variable"
        case .form: "list.bullet.rectangle"
        case .site: "globe"
        }
    }
}
