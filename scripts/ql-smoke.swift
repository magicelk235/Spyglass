// Off-screen Quick Look host for smoke-testing the preview extension.
//
// Shows each file in a QLPreviewView inside a borderless window that never
// takes focus, so previews resolve and run exactly as in Finder without
// stealing the screen. --show keeps the window visible (behind every other
// window) so a window screenshot tool can capture it.
//
//   ql-smoke [--dark|--light] [--show] [--wait SECONDS] FILE...

import AppKit
import Quartz

var args = Array(CommandLine.arguments.dropFirst())
var appearance: NSAppearance.Name?
var visible = false
var wait = 3.0
var files: [String] = []
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--dark": appearance = .darkAqua
    case "--light": appearance = .aqua
    case "--show": visible = true
    case "--wait": wait = Double(args.removeFirst()) ?? wait
    default: files.append(arg)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
if let appearance { app.appearance = NSAppearance(named: appearance) }

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.title = "Spyglass smoke"
window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
window.collectionBehavior = [.stationary, .ignoresCycle]
window.alphaValue = visible ? 1 : 0
let preview = QLPreviewView(frame: window.contentView!.bounds, style: .normal)!
preview.autoresizingMask = [.width, .height]
window.contentView = preview
window.orderBack(nil)

Task { @MainActor in
    for path in files {
        print("SHOW \(path)")
        fflush(stdout)
        preview.previewItem = URL(fileURLWithPath: path) as NSURL
        try? await Task.sleep(for: .seconds(wait))
    }
    exit(0)
}
app.run()
