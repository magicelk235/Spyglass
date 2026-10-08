// Renders files through the same FormatPreview code the Quick Look extension
// uses and writes each result to a PNG. Needs no Screen Recording permission
// and no installed extension, so it works for checking how a renderer looks.
// It runs outside the extension sandbox: use scripts/ql-smoke.sh to check
// routing and sandbox behavior.
//
//   PreviewHarness [--dark|--light] [--size WxH] [--wait SECONDS] --out DIR FILE...

import AppKit
import WebKit
import SpyglassKit

var args = Array(CommandLine.arguments.dropFirst())
var appearanceName: NSAppearance.Name = .aqua
var size = NSSize(width: 900, height: 640)
var wait = 1.5
var outDir = URL(fileURLWithPath: "/tmp/spyglass-harness", isDirectory: true)
var files: [URL] = []
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--dark": appearanceName = .darkAqua
    case "--light": appearanceName = .aqua
    case "--size":
        let parts = args.removeFirst().split(separator: "x").compactMap { Double($0) }
        if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
    case "--wait": wait = Double(args.removeFirst()) ?? wait
    case "--out": outDir = URL(fileURLWithPath: args.removeFirst(), isDirectory: true)
    default: files.append(URL(fileURLWithPath: arg).standardizedFileURL)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.appearance = NSAppearance(named: appearanceName)

let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.appearance = NSAppearance(named: appearanceName)
window.orderBack(nil)

/// A view that paints the window background Quick Look's panel would draw
/// behind the preview, so transparent previews snapshot correctly.
final class PanelBackground: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}

/// Snapshot of `view`, with every WKWebView inside it replaced by the web
/// view's own snapshot (cacheDisplay leaves web content blank).
@MainActor
func snapshot(_ view: NSView) async -> NSBitmapImageRep? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    var webViews: [WKWebView] = []
    func collect(_ v: NSView) {
        if let web = v as? WKWebView { webViews.append(web) } else { v.subviews.forEach(collect) }
    }
    collect(view)
    guard !webViews.isEmpty else { return rep }
    var webImages: [(NSImage, NSRect)] = []
    for web in webViews {
        guard let image = try? await web.takeSnapshot(configuration: nil) else { continue }
        let frame = web.convert(web.bounds, to: view)
        let rect = view.isFlipped
            ? NSRect(x: frame.minX, y: view.bounds.height - frame.maxY, width: frame.width, height: frame.height)
            : frame
        webImages.append((image, rect))
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (image, rect) in webImages { image.draw(in: rect) }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

Task { @MainActor in
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let settings = PreviewSettings.load()
    let suffix = appearanceName == .darkAqua ? "dark" : "light"
    for url in files {
        let uti = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
        let kind = PreviewKind.route(filename: url.lastPathComponent, uti: uti)
        let started = Date()
        let view = await FormatPreview.makeView(kind: kind, url: url, settings: settings)
        let elapsed = Date().timeIntervalSince(started)
        let container = PanelBackground(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(wait))
        let out = outDir.appendingPathComponent("\(url.lastPathComponent)-\(suffix).png")
        if let rep = await snapshot(container), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: out)
            print(String(format: "%@\tkind=%@\tready=%.2fs\t%@", url.lastPathComponent,
                         kind.map { "\($0)" } ?? "none", elapsed, out.path))
        } else {
            print("\(url.lastPathComponent)\tSNAPSHOT-FAILED")
        }
        fflush(stdout)
    }
    exit(0)
}
app.run()
