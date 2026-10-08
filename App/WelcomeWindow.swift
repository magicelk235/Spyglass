import AppKit
import SwiftUI

/// Shown once, the first time Spyglass runs. A menu-bar app otherwise starts
/// with no visible sign that anything happened, so this says what to do next
/// and that the trial has started.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: WelcomeWindowController?
    private static let shownKey = "welcomeShown"

    static func showIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return }
        UserDefaults.standard.set(true, forKey: shownKey)
        let controller = WelcomeWindowController()
        shared = controller
        controller.showWindow(nil)
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: WelcomeView { [weak window] in window?.close() })
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        AppActivationPolicy.enter()
    }

    func windowWillClose(_ notification: Notification) {
        AppActivationPolicy.leave()
        Self.shared = nil
    }
}

private struct WelcomeView: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            Text("Spyglass is ready").font(.title2).bold()
            VStack(alignment: .leading, spacing: 12) {
                step("cursorarrow.click", "Select a file in Finder and press Space.")
                step("doc.richtext", "Markdown, code, notebooks, archives, apps, folders and more now preview properly.")
                step("gift", "Every preview is free for 7 days. Unlock Pro from the menu-bar icon any time.")
                step("menubar.arrow.up.rectangle", "Spyglass lives in your menu bar. Google Drive setup is there too.")
            }
            .frame(maxWidth: 360, alignment: .leading)
            Button("Get Started", action: close)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
        .frame(width: 440)
    }

    private func step(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }
}
