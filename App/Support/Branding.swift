import Foundation

/// Every product-name-shaped string in the app funnels through here, so renaming
/// the app is a `project.yml` edit (plus `scripts/rename.sh`) and nothing else.
///
/// The display name is read from the bundle at runtime rather than hardcoded —
/// change `CFBundleName` and the menus, window titles and permission alerts all
/// follow. Two constants at the bottom are deliberately frozen: they are *data
/// identity*, not branding, and renaming them would orphan the user's database
/// or break previously exported files.
enum Branding {
    /// User-facing app name (from `CFBundleName`).
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? fallbackName
    }

    /// Subsystem for `Log` and any other bundle-scoped identifier.
    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.mukker.Mukker"
    }

    static let repoURL = URL(string: "https://github.com/miklos-szel/mukker")!

    /// Used only when the Info.plist can't be read (unit tests run without one).
    private static let fallbackName = "Mukker"

    // MARK: - Frozen identity (must NOT follow a rename)

    /// Name of the Application Support folder holding the SQLite database and its
    /// image/RTF sidecars. Changing this orphans every existing user's history —
    /// only ever change it together with a `LegacyDataMigrator` step that adopts
    /// the old folder (see `legacySupportFolderNames`).
    static let supportFolderName = "Mukker"

    /// File name of the SQLite database inside `supportFolderName`.
    static let databaseFileName = "mukker.sqlite"

    /// Wire format string written into native snippet exports. Changing this makes
    /// files exported by older builds unreadable unless the importer keeps
    /// accepting the old value — see `MukkerExport.acceptedFormats`.
    static let snippetExportFormat = "mukker.snippets.v1"
}
