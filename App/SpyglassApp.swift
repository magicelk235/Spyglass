import SwiftUI
import ServiceManagement

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
        worker.start()
        scanner.start()
        // Keep the agent alive across logins so previews stay warm. Personal
        // build: failure (e.g. user declined) is non-fatal, just less coverage.
        try? SMAppService.mainApp.register()
    }

    var body: some Scene {
        MenuBarExtra("Spyglass", systemImage: "mountain.2.fill") {
            ContentView()
                .environmentObject(auth)
                .onAppear { auth.restore() }
        }
        .menuBarExtraStyle(.window)   // hosts the full ContentView as a popover
    }
}
