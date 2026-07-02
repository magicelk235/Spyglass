import Foundation
import AppKit

/// Detects whether DrivePeak can actually read the Google Drive mounts, and
/// opens the Full Disk Access pane if not.
///
/// The scanner sweeps `~/Library/CloudStorage/GoogleDrive-*` to discover stubs.
/// macOS gates that directory behind Full Disk Access — without it, the
/// enumerator returns nothing and no Tier 1 previews are ever fetched. We can't
/// request FDA programmatically, so we detect the gap and point the user to
/// System Settings.
enum DriveAccess {
    /// True when a Google Drive mount exists but we can't enumerate it —
    /// i.e. FDA is almost certainly missing. False when there's no Drive at all
    /// (nothing to grant) or we can read it fine.
    static func isBlocked() -> Bool {
        let fm = FileManager.default
        let cloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        guard let entries = try? fm.contentsOfDirectory(atPath: cloud.path) else { return false }
        let mounts = entries.filter { $0.hasPrefix("GoogleDrive-") }
        guard !mounts.isEmpty else { return false }   // no Drive → nothing to unblock
        // If every mount lists as empty, the read is being blocked (a real,
        // signed-in Drive always has at least "My Drive").
        return mounts.allSatisfy { mount in
            let contents = try? fm.contentsOfDirectory(atPath: cloud.appendingPathComponent(mount).path)
            return (contents?.isEmpty ?? true)
        }
    }

    /// Opens System Settings › Privacy & Security › Full Disk Access.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
