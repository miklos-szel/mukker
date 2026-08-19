import Foundation

/// One-shot import of data left behind by the two pre-merge apps.
///
/// The merged app keeps the clipboard app's bundle identifier, so its database
/// and preferences are already in place and need no work. Two things do:
///
/// 1. **The database**, if it isn't where we expect it — either because the app
///    was renamed (a rename changes `CFBundleName`, and a user may have moved
///    the Application Support folder to match) or because only an older
///    differently-named install exists. We copy rather than move, so the old app
///    keeps working if the user rolls back.
/// 2. **The capture app's preferences**, which lived in its own defaults domain
///    (`com.mukker.Mukker`) and would otherwise be lost. Keys are copied only
///    when we don't already have a value, so a fresh setting always wins.
///
/// Runs before anything reads the database or the settings objects — see
/// `AppDelegate.applicationDidFinishLaunching`.
@MainActor
enum LegacyDataMigrator {

    /// Bumping this re-runs the migration once for existing installs.
    private static let currentVersion = 1
    private static let versionKey = "migration.legacyImportVersion"

    /// Defaults domain of the pre-merge capture app.
    private static let captureAppDomain = "com.mukker.Mukker"

    /// Application Support folder names that may hold a database we can adopt.
    private static let legacySupportFolderNames = ["Sniptory", "Mukker"]

    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: versionKey) < currentVersion else { return }
        adoptLegacyDatabaseIfMissing()
        importCaptureDefaults(into: defaults)
        defaults.set(currentVersion, forKey: versionKey)
        Log.app.info("legacy data migration completed (v\(currentVersion, privacy: .public))")
    }

    // MARK: - Database + sidecars

    /// If our support directory has no database, copy one in from a legacy
    /// location (database, its WAL/SHM siblings, and the image/rich-text sidecars).
    private static func adoptLegacyDatabaseIfMissing() {
        let fm = FileManager.default
        let target = AppPaths.supportDirectory
        guard !fm.fileExists(atPath: AppPaths.databaseURL.path) else { return }

        guard let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil,
                                           create: false) else { return }

        let candidates = (legacySupportFolderNames + [Branding.name])
            .filter { $0 != Branding.supportFolderName }
            .map { appSupport.appendingPathComponent($0, isDirectory: true) }

        guard let source = candidates.first(where: {
            fm.fileExists(atPath: $0.appendingPathComponent("sniptory.sqlite").path)
        }) else { return }

        let items = ["sniptory.sqlite", "sniptory.sqlite-wal", "sniptory.sqlite-shm",
                     "images", "richtext"]
        for item in items {
            let from = source.appendingPathComponent(item)
            let to = target.appendingPathComponent(item)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            do {
                try fm.copyItem(at: from, to: to)
            } catch {
                Log.app.error("migration: could not copy \(item, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        Log.app.info("migration: adopted database from \(source.lastPathComponent, privacy: .public)")
    }

    // MARK: - Preferences

    /// Keys owned by `CaptureSettings` / `ShortcutSettings`, which used to live in
    /// the capture app's own defaults domain. Listed explicitly rather than copying
    /// the whole domain so we never import stale or unknown state.
    private static let captureKeys = [
        // CaptureSettings
        "saveDirectory", "saveFormat", "downscaleRetina", "afterCapture",
        "showMagnifierDuringCapture", "closeAfterCopy", "closeAfterSave",
        "escCopiesAndCloses", "defaultColorIndex", "defaultTextColorIndex",
        "defaultTextSize", "defaultLineWidth", "canvasPadding", "enableDebugMenu",
        "toolShortcuts", "scrollMaxHeight", "scrollSpeed",
        // ShortcutSettings (same key names and dictionary format as before the merge)
        "areaCombo", "fullscreenCombo", "scrollCombo"
    ]

    private static func importCaptureDefaults(into defaults: UserDefaults) {
        guard let legacy = UserDefaults(suiteName: captureAppDomain) else { return }
        var imported = 0
        for key in captureKeys {
            guard defaults.object(forKey: key) == nil,
                  let value = legacy.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
            imported += 1
        }
        if imported > 0 {
            Log.app.info("migration: imported \(imported, privacy: .public) capture preferences")
        }
    }
}
