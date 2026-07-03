import Foundation
import AppKit

/// Detects whether Spyglass has the Full Disk Access it needs to read the
/// Google Drive mounts, and opens the FDA pane if not.
///
/// The scanner sweeps `~/Library/CloudStorage/GoogleDrive-*` to discover stubs
/// and render Tier 1 previews. macOS gates reading real Drive file contents
/// behind Full Disk Access. We can't request FDA programmatically, so we detect
/// the gap and point the user to System Settings.
enum DriveAccess {
    /// True when the user has a Google Drive mount but Spyglass lacks Full Disk
    /// Access. False when there's no Drive at all (nothing to grant) or access
    /// is already granted.
    ///
    /// Access is detected by trying to read a well-known TCC-protected file.
    /// Reading these requires Full Disk Access and — importantly — does NOT
    /// trigger a permission prompt, so it's a silent, deterministic probe.
    /// (Probing Drive files directly is unreliable: `open()` succeeds on
    /// not-yet-downloaded placeholder files regardless of access.)
    static func isBlocked() -> Bool {
        let fm = FileManager.default

        // Nothing to unblock if the user has no Google Drive mount.
        let cloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        guard let entries = try? fm.contentsOfDirectory(atPath: cloud.path),
              entries.contains(where: { $0.hasPrefix("GoogleDrive-") }) else {
            return false
        }

        return !hasFullDiskAccess()
    }

    /// Reads a byte from a TCC-protected canary file. Success ⇒ Full Disk Access
    /// is granted. We try several because Apple doesn't guarantee any single
    /// path exists (e.g. Safari may be absent, TCC.db path isn't a stable API).
    private static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let canaries = [
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Library/Safari/CloudTabs.db",
            "Library/Safari/Bookmarks.plist",
            "Library/Messages/chat.db",
        ].map { home.appendingPathComponent($0) }

        var anyExisted = false
        for url in canaries {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            anyExisted = true
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { continue }   // EPERM here → try next canary
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            close(fd)
            if n >= 0 { return true }          // read succeeded → FDA granted
        }
        // A canary existed but none could be opened/read → access is denied.
        // If none existed at all we can't tell, so assume granted rather than
        // nagging a user who may genuinely have access.
        return !anyExisted
    }

    /// Opens System Settings › Privacy & Security › Full Disk Access.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
