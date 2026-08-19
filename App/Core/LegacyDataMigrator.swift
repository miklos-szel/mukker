import Foundation

/// One-shot adoption of data written under a previous identity.
///
/// This app has been renamed (and its bundle identifier changed) since users
/// started storing data in it, so on launch it may find its database and
/// preferences under an older name. Both are brought forward here, before
/// anything reads them.
///
/// - **Database + sidecars.** Copied — never moved — from the newest legacy
///   support folder that has one, so an older build still works if the user
///   rolls back.
/// - **Preferences.** Copied from the previous bundle identifier's defaults
///   domain. A bundle-ID change means macOS hands us an empty domain, and it
///   also resets TCC (Accessibility / Screen Recording) — permissions are the
///   one thing we cannot migrate; the user has to grant them once more.
///
/// Bump `currentVersion` to re-run the whole migration for existing installs.
@MainActor
enum LegacyDataMigrator {

    private static let currentVersion = 2
    private static let versionKey = "migration.legacyImportVersion"

    /// Defaults domains this app has previously written to, oldest first. The
    /// last match wins, so the most recent identity's values take precedence.
    private static let legacyDefaultsDomains = [
        "com.mukker.Mukker",       // pre-merge capture app
        "com.sniptory.Sniptory"    // merged app, before the Mukker identity
    ]

    /// Database locations this app has previously used, in priority order:
    /// `(Application Support folder, database file name)`.
    private static let legacyDatabases = [
        (folder: "Mukker", file: "sniptory.sqlite"),
        (folder: "Sniptory", file: "sniptory.sqlite")
    ]

    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: versionKey) < currentVersion else { return }
        adoptLegacyDatabaseIfMissing()
        importLegacyDefaults(into: defaults)
        defaults.set(currentVersion, forKey: versionKey)
        Log.app.info("legacy data migration completed (v\(currentVersion, privacy: .public))")
    }

    // MARK: - Database + sidecars

    /// If our support directory has no database, copy one in from a legacy
    /// location — the database, its WAL/SHM siblings (renamed to match our file
    /// name), and the image / rich-text sidecar directories.
    private static func adoptLegacyDatabaseIfMissing() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: AppPaths.databaseURL.path) else { return }
        guard let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil,
                                           create: false) else { return }

        let current = (folder: Branding.supportFolderName, file: Branding.databaseFileName)
        guard let source = legacyDatabases.first(where: { candidate in
            candidate != current && fm.fileExists(
                atPath: appSupport.appendingPathComponent(candidate.folder)
                                  .appendingPathComponent(candidate.file).path)
        }) else { return }

        let from = appSupport.appendingPathComponent(source.folder, isDirectory: true)
        let to = AppPaths.supportDirectory

        // The database keeps its contents but takes our file name; the WAL and
        // SHM siblings must follow it or SQLite won't find them.
        for suffix in ["", "-wal", "-shm"] {
            copy(from.appendingPathComponent(source.file + suffix),
                 to: to.appendingPathComponent(Branding.databaseFileName + suffix))
        }
        for directory in ["images", "richtext"] {
            copy(from.appendingPathComponent(directory), to: to.appendingPathComponent(directory))
        }
        Log.app.info("migration: adopted database from \(source.folder, privacy: .public)")
    }

    private static func copy(_ from: URL, to: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return }
        do {
            try fm.copyItem(at: from, to: to)
        } catch {
            Log.app.error("migration: could not copy \(from.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Preferences

    /// Copies our own keys out of each previous defaults domain. Later domains
    /// overwrite earlier ones because they hold the more recent settings; keys
    /// belonging to macOS (window frames, colour panel state) and this
    /// migrator's own bookkeeping are skipped.
    /// `domains` is injectable so tests can exercise the precedence rules without
    /// reading the real user's preferences.
    static func importLegacyDefaults(into defaults: UserDefaults,
                                     from domains: [String] = legacyDefaultsDomains) {
        var imported = 0
        for domain in domains where domain != Branding.bundleID {
            guard let legacy = defaults.persistentDomain(forName: domain) else { continue }
            for (key, value) in legacy where isAppOwned(key) {
                defaults.set(value, forKey: key)
                imported += 1
            }
        }
        if imported > 0 {
            Log.app.info("migration: imported \(imported, privacy: .public) preferences")
        }
    }

    private static func isAppOwned(_ key: String) -> Bool {
        if key.hasPrefix("migration.") { return false }
        for prefix in ["NS", "Apple", "com.apple"] where key.hasPrefix(prefix) { return false }
        return true
    }
}
