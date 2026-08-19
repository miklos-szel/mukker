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
        Bundle.main.bundleIdentifier ?? "com.sniptory.Sniptory"
    }

    static let repoURL = URL(string: "https://github.com/miklos-szel/sniptory")!

    /// Used only when the Info.plist can't be read (unit tests run without one).
    private static let fallbackName = "Sniptory"

    // MARK: - Frozen identity (must NOT follow a rename)

    /// Name of the Application Support folder holding the SQLite database and its
    /// image/RTF sidecars. Renaming this orphans every existing user's history.
    static let supportFolderName = "Sniptory"

    /// Wire format string for native snippet export. Renaming this makes files
    /// exported by older builds unreadable.
    static let snippetExportFormat = "sniptory.snippets.v1"
}
