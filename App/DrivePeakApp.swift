import SwiftUI

@main
struct DrivePeakApp: App {
    @StateObject private var auth = GoogleAuth()
    // Held for the app's lifetime; starts draining/watching on launch, including
    // headless launches triggered by the Quick Look extension.
    private let worker = FetchWorker()

    init() {
        worker.start()
    }

    var body: some Scene {
        MenuBarExtra("DrivePeak", systemImage: "eye.circle.fill") {
            ContentView()
                .environmentObject(auth)
                .onAppear { auth.restore() }
        }
        .menuBarExtraStyle(.window)   // hosts the full ContentView as a popover
    }
}
