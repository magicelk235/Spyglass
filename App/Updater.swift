import Foundation
import Sparkle

/// Self-updating through Sparkle. The feed URL, public key and automatic
/// install preference live in Info.plist; the feed is the `appcast.xml`
/// attached to every GitHub release, so `/releases/latest/download` always
/// resolves to the newest one.
///
/// Spyglass never quits on its own (it lives in the menu bar), so an update
/// that waits for the app to quit could sit staged for weeks. Install it as
/// soon as it's downloaded instead; the Quick Look extension is reloaded by
/// the system with the new app.
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

    func start() {
        _ = controller
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Shows Sparkle's own UI, including "You're up to date".
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        immediateInstallationBlock()
        return true
    }
}
