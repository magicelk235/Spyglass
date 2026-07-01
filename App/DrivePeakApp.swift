import SwiftUI

@main
struct DrivePeakApp: App {
    @StateObject private var auth = GoogleAuth()

    var body: some Scene {
        Window("DrivePeak", id: "main") {
            ContentView()
                .environmentObject(auth)
                .onAppear { auth.restore() }
        }
        .windowResizability(.contentSize)
    }
}
