import Foundation
import OSLog
import SpyglassKit

private let log = Logger(subsystem: "com.spyglass.app", category: "license")

/// The popover's view of `LicenseStore`. Starts the trial on first launch and
/// re-asks Gumroad about the stored key at launch and once a day, so a lapsed
/// Drive membership or a refund takes effect without the user doing anything.
@MainActor
final class LicenseModel: ObservableObject {
    @Published private(set) var access: LicenseStore.Access = .notStarted
    @Published private(set) var plan: LicenseStore.Plan?
    @Published private(set) var licenseKey: String?
    @Published private(set) var activating = false
    @Published var error: String?

    private let store = LicenseStore()
    private var timer: Timer?

    init() {
        store.startTrialIfNeeded()
        refresh()
        log.notice("Previews this week: \(UsageStats.inApp().week().total)")
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { await self?.recheck() }
        }
    }

    /// Re-reads the store; the trial's days left change with the clock.
    func refresh() {
        access = store.access()
        plan = store.plan
        licenseKey = store.licenseKey
    }

    func activate(_ key: String) async {
        activating = true
        error = nil
        defer { activating = false }
        do {
            let plan = try await store.activate(key: key)
            log.notice("Activated \(plan.rawValue, privacy: .public) license")
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func deactivate() {
        store.clear()
        refresh()
    }

    private func recheck() async {
        do {
            try await store.recheck()
        } catch {
            log.notice("License check skipped: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}
