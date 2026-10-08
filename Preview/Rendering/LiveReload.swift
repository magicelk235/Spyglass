import AppKit
import WebKit

/// Calls `onChange` on the main queue, debounced, when a file or folder
/// changes on disk. Follows atomic saves: most editors write a new file and
/// rename it over the old one, which ends the old descriptor's life, so the
/// watcher re-opens whatever is at the path afterwards.
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        path = url.path
        self.onChange = onChange
        watch(attempt: 0)
    }

    deinit {
        pending?.cancel()
        source?.cancel()
    }

    private func watch(attempt: Int) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // Mid-save there can briefly be nothing at the path.
            guard attempt < 20 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.watch(attempt: attempt + 1)
            }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if !src.data.isDisjoint(with: [.delete, .rename]) {
                src.cancel()
                self.source = nil
                self.watch(attempt: 0)
            }
            self.scheduleChange()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    /// Saves often arrive as several events; render once they settle.
    private func scheduleChange() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
}

/// Where the reader was in a preview, so a reload can put them back there.
@MainActor
enum ScrollMemory {

    enum Position {
        case web(CGFloat)
        case native(NSPoint)
    }

    static func capture(in view: NSView) async -> Position? {
        if let web = find(WKWebView.self, in: view) {
            let y = try? await web.evaluateJavaScript("window.scrollY") as? Double
            return y.map { .web(CGFloat($0)) }
        }
        if let scroll = find(NSScrollView.self, in: view) {
            return .native(scroll.contentView.bounds.origin)
        }
        return nil
    }

    /// Applies the position now and again shortly after: web previews keep
    /// rendering (highlighting, diagrams) after load, which grows the page.
    static func restore(_ position: Position?, in view: NSView) {
        guard let position else { return }
        for delay in [0.0, 0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                apply(position, in: view)
            }
        }
    }

    private static func apply(_ position: Position, in view: NSView) {
        switch position {
        case .web(let y):
            find(WKWebView.self, in: view)?.evaluateJavaScript("window.scrollTo(window.scrollX, \(y))")
        case .native(let origin):
            guard let scroll = find(NSScrollView.self, in: view) else { return }
            view.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let match = find(type, in: sub) { return match }
        }
        return nil
    }
}
