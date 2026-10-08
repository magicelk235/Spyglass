import Foundation

/// Moves what 1.0 stored in `AppGroup.legacyIdentifier` into the current
/// group: the license and the cached Drive previews. Runs in the app at every
/// launch; once nothing is left to move it does nothing. Never overwrites
/// anything already in the current group.
public enum LegacyGroupMigration {

    public static func run(
        legacyDefaults: UserDefaults?, legacyContainer: URL?,
        defaults: UserDefaults?, container: URL?
    ) {
        // 1.0 stored a key and an `isPro` flag; LicenseStore reads that pair
        // as the 1.0 plan.
        if let legacyDefaults, let defaults,
           defaults.string(forKey: LicenseStore.keyKey) == nil,
           let key = legacyDefaults.string(forKey: LicenseStore.keyKey) {
            defaults.set(key, forKey: LicenseStore.keyKey)
            defaults.set(legacyDefaults.bool(forKey: LicenseStore.proKey), forKey: LicenseStore.proKey)
        }

        guard let legacyContainer, let container else { return }
        let fm = FileManager.default
        let from = legacyContainer.appendingPathComponent("previews", isDirectory: true)
        let to = container.appendingPathComponent("previews", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil),
              !files.isEmpty else { return }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        for file in files {
            let target = to.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                try? fm.removeItem(at: file)
            } else {
                try? fm.moveItem(at: file, to: target)
            }
        }
    }

    /// The real groups.
    public static func run() {
        run(legacyDefaults: UserDefaults(suiteName: AppGroup.legacyIdentifier),
            legacyContainer: FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroup.legacyIdentifier),
            defaults: UserDefaults(suiteName: AppGroup.identifier),
            container: AppGroup.containerURL)
    }
}
