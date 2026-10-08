import AppKit
import OSLog
import SpyglassKit
import UniformTypeIdentifiers
import WebKit

private let log = Logger(subsystem: "com.spyglass.app.preview", category: "web")

/// What the web shell (`Web/shell.html`) renders. Encoded as JSON and
/// injected as `window.spyglassPayload` before the page's own scripts run.
struct WebPayload: Encodable, Sendable {
    enum Mode: String, Encodable, Sendable { case code, markdown, diff }

    var mode: Mode
    var text = ""
    /// highlight.js language id; nil asks the page to auto-detect.
    var language: String?
    var theme: PreviewSettings.Theme
    var fontSize: Double
    /// `text` is only the start of the file.
    var truncated = false
    /// How many characters of `text` get syntax colors; nil means all.
    var highlightLimit: Int?
    /// The previewed file's folder, which Markdown's relative images resolve against.
    var baseURL: String?
    /// Diff mode: the parsed patch.
    var files: [UnifiedDiff.File]?
    var preamble: String?

    init(mode: Mode, settings: PreviewSettings) {
        self.mode = mode
        theme = settings.theme
        fontSize = settings.codeFontSize
    }

    /// Code mode for `text`. Past `highlightLimit` characters the rest stays
    /// plain; the returned note part says so.
    static func code(_ text: String, language: String?, highlightLimit: Int,
                     settings: PreviewSettings) -> (payload: WebPayload, note: String?) {
        var payload = WebPayload(mode: .code, settings: settings)
        payload.text = text
        payload.language = language
        guard language != "plaintext", text.utf16.count > highlightLimit else { return (payload, nil) }
        payload.highlightLimit = highlightLimit
        return (payload, "Highlighting the first \(PreviewNote.size(highlightLimit))")
    }
}

/// Builds the WKWebView previews for code, structured text, Markdown and
/// diffs from the bundled shell.
@MainActor
enum WebRenderer {

    /// URL scheme the page uses for images next to a Markdown file.
    static let imageScheme = "spyglass-local"

    /// Shared by every preview. Ephemeral, so nothing is written to disk: no
    /// cookies, caches or web storage.
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    /// The bundled `Web` folder. The extension and the preview harness both
    /// carry it in their Resources.
    static var resources: URL? {
        Bundle.main.url(forResource: "Web", withExtension: nil)
    }

    /// Loads the shell with `payload` and returns once the page has finished
    /// loading, by which point the first screenful is rendered. Throws when
    /// the page fails to load.
    static func makeView(_ payload: WebPayload, settings: PreviewSettings,
                         servesLocalImages: Bool = false) async throws -> NSView {
        guard let folder = resources else {
            throw RenderError.unsupported("the Web folder is missing from the bundle")
        }
        let script = try await Task.detached(priority: .userInitiated) {
            try userScript(for: payload)
        }.value

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if servesLocalImages {
            configuration.setURLSchemeHandler(LocalImageLoader(), forURLScheme: imageScheme)
        }

        let view = PreviewWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        // FormatPreview applies the theme too, but only after this returns.
        // Setting it first means the page renders in the right colors from
        // the start rather than flipping once it's on screen.
        switch settings.theme {
        case .system: break
        case .light: view.appearance = NSAppearance(named: .aqua)
        case .dark: view.appearance = NSAppearance(named: .darkAqua)
        }
        try await view.loadShell(folder.appendingPathComponent("shell.html"), readAccess: folder)
        return view
    }

    nonisolated static func userScript(for payload: WebPayload) throws -> String {
        let json = try JSONEncoder().encode(payload)
        return "window.spyglassPayload = " + String(decoding: json, as: UTF8.self) + ";"
    }
}

/// A web view that loads exactly one page, the shell, and cancels every
/// other navigation: link clicks, scripted redirects, reloads, frames.
/// Together with the shell's CSP this keeps previews off the network.
final class PreviewWebView: WKWebView, WKNavigationDelegate {

    private var shell: URL?
    private var pending: CheckedContinuation<Void, Error>?

    func loadShell(_ shell: URL, readAccess folder: URL) async throws {
        self.shell = shell.resolvingSymlinksInPath()
        navigationDelegate = self
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pending = continuation
                loadFileURL(shell, allowingReadAccessTo: folder)
            }
        } onCancel: {
            Task { @MainActor in self.finishLoading(CancellationError()) }
        }
    }

    private func finishLoading(_ error: Error?) {
        guard let pending else { return }
        self.pending = nil
        if let error {
            stopLoading()
            pending.resume(throwing: error)
        } else {
            pending.resume()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let isShell = pending != nil
            && navigationAction.targetFrame?.isMainFrame == true
            && url?.isFileURL == true
            && url?.resolvingSymlinksInPath().path == shell?.path
        if !isShell {
            log.notice("Blocked navigation to \(url?.scheme ?? "nil", privacy: .public) URL")
        }
        decisionHandler(isShell ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("Web content process ended")
        finishLoading(RenderError.unsupported("the web content process ended"))
    }
}

/// Serves `spyglass-local:` requests from Markdown previews. The URL's path
/// is a file on disk; only image files this process can read are served.
/// Anything else fails, and the page then drops the image. In the extension
/// sandbox that usually means images beside the file stay out.
@MainActor
final class LocalImageLoader: NSObject, WKURLSchemeHandler {

    nonisolated static let maxImageSize = 32 << 20

    private var running: [ObjectIdentifier: any WKURLSchemeTask] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        running[key] = urlSchemeTask
        guard let url = urlSchemeTask.request.url else {
            running[key] = nil
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path
        Task {
            let result = await Task.detached(priority: .utility) { Self.readImage(atPath: path) }.value
            // A task the web view stopped meanwhile must not be answered.
            guard let task = running.removeValue(forKey: key) else { return }
            switch result {
            case .success(let image):
                task.didReceive(URLResponse(url: url, mimeType: image.mimeType,
                                            expectedContentLength: image.data.count, textEncodingName: nil))
                task.didReceive(image.data)
                task.didFinish()
            case .failure(let error):
                task.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        running[ObjectIdentifier(urlSchemeTask)] = nil
    }

    struct Image: Sendable {
        var data: Data
        var mimeType: String
    }

    nonisolated static func readImage(atPath path: String) -> Result<Image, Error> {
        let url = URL(fileURLWithPath: path)
        do {
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                  let type = values.contentType, type.conforms(to: .image),
                  let size = values.fileSize, size <= maxImageSize
            else { throw URLError(.resourceUnavailable) }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return .success(Image(data: data, mimeType: type.preferredMIMEType ?? "application/octet-stream"))
        } catch {
            return .failure(error)
        }
    }
}

/// The start of a text file, as much as a preview shows.
struct FilePrefix: Sendable {
    var text: String
    /// The file is longer than `text`.
    var truncated: Bool
    var fileSize: Int

    /// Reads at most `limit` bytes. Throws for files that aren't text.
    static func read(_ url: URL, limit: Int) throws -> FilePrefix {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        let truncated = data.count > limit
        guard let text = TextSniffer.decode(truncated ? data.prefix(limit) : data) else {
            throw RenderError.unsupported("\(url.lastPathComponent) isn't text")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? data.count
        return FilePrefix(text: text, truncated: truncated, fileSize: size)
    }

    /// "Showing the first 2 MB of 3.4 MB", or nil for a whole file.
    func shownPart(limit: Int) -> String? {
        guard truncated else { return nil }
        return "Showing the first \(PreviewNote.size(limit)) of \(PreviewNote.size(fileSize))"
    }
}

/// Wording for the banner over a partial preview.
enum PreviewNote {
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The parts on one line, or nil when there are none.
    static func joined(_ parts: [String?]) -> String? {
        let parts = parts.compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
