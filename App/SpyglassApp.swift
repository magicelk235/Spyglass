import SwiftUI
import ServiceManagement
import SpyglassKit

@main
struct SpyglassApp: App {
    @StateObject private var auth = GoogleAuth()
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
        worker.start()
        scanner.start()
        // Keep the agent alive across logins so previews stay warm. Personal
        // build: failure (e.g. user declined) is non-fatal, just less coverage.
        try? SMAppService.mainApp.register()
    }

    var body: some Scene {
        MenuBarExtra("Spyglass", image: "SpyglassMenuBar") {
            ContentView()
                .environmentObject(auth)
                .onAppear { auth.restore() }
        }
        .menuBarExtraStyle(.window)   // hosts the full ContentView as a popover
    }
}
