import Foundation

/// The six Google Workspace stub file types Spyglass previews.
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
    public var uti: String { "com.spyglass.\(rawValue)" }

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

    /// Whether Tier 1 has any rendered-preview path for this type. Exportable
    /// types render their PDF export; Forms/Sites render the Drive-hosted
    /// thumbnail (wrapped as a PDF). Every type is previewable → the scanner
    /// enqueues all of them.
    public var isPreviewable: Bool { true }

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

    /// Brand color as sRGB components (0–1). Kept as a tuple so the model layer
    /// stays free of any UI framework; the view maps it to a `Color`.
    /// Values approximate each product's official brand color.
    public var brandColor: (red: Double, green: Double, blue: Double) {
        switch self {
        case .doc:     (0.26, 0.52, 0.96)  // #4285F4 blue
        case .sheet:   (0.13, 0.66, 0.42)  // #22A45D green
        case .slides:  (0.96, 0.73, 0.20)  // #F4B933 yellow
        case .drawing: (0.85, 0.32, 0.24)  // #D9513D red
        case .form:    (0.49, 0.24, 0.64)  // #7E3DA3 purple
        case .site:    (0.02, 0.62, 0.60)  // #049E99 teal
        }
    }
}
