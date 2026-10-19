import SwiftUI
import ServiceManagement
import SpyglassKit

@main
struct SpyglassApp: App {
    private let auth = GoogleAuth()
    private let license: LicenseModel
    // Held for the app's lifetime. The worker drains/fetches queued docIDs;
    // the scanner discovers stub files on disk and enqueues them. Together
    // they keep the shared preview cache warm — the write-locked Quick Look
    // extension can only read it.
    private let worker = FetchWorker()
    private let scanner = StubScanner()

    init() {
        // Before anything opens the App Group: 1.0 kept the license and cache
        // in a group the Quick Look extension can no longer read.
        LegacyGroupMigration.run()
        license = LicenseModel()
        worker.start()
        scanner.start()
        // Keep the agent alive across logins so previews stay warm. Personal
        // build: failure (e.g. user declined) is non-fatal, just less coverage.
        try? SMAppService.mainApp.register()
        Updater.shared.start()
        DispatchQueue.main.async { WelcomeWindowController.showIfFirstLaunch() }
    }

    var body: some Scene {
        MenuBarExtra("Spyglass", image: "SpyglassMenuBar") {
            Button("Settings…") { SettingsWindowController.show(auth: auth, license: license) }
                .keyboardShortcut(",")
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
            Divider()
            Button("Quit Spyglass") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
