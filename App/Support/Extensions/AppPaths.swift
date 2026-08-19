import Foundation

/// Filesystem locations for both feature sets. The Application Support folder
/// name comes from `Branding.supportFolderName` (frozen across renames) while
/// the saved-screenshot filename prefix follows the current display name.
enum AppPaths {

    // MARK: - Clipboard / snippets storage

    static var supportDirectory: URL {
        let fm = FileManager.default
        let base = try! fm.url(for: .applicationSupportDirectory,
                               in: .userDomainMask,
                               appropriateFor: nil,
                               create: true)
        let dir = base.appendingPathComponent(Branding.supportFolderName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var databaseURL: URL {
        supportDirectory.appendingPathComponent("sniptory.sqlite")
    }

    static var imagesDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var richTextDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("richtext", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Default location for the "forever history" archive: ~/Documents/<app>.
    static var defaultForeverHistoryDirectory: URL {
        let fm = FileManager.default
        let docs = (try? fm.url(for: .documentDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return docs.appendingPathComponent(Branding.supportFolderName, isDirectory: true)
    }

    // MARK: - Screen capture output

    /// Default directory for saved screenshots (the Desktop, falling back to ~).
    static var defaultSaveDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Built once — DateFormatter construction is expensive relative to a save.
    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    /// A timestamped file name like "Sniptory 2026-05-29 at 09.41.12.png".
    static func suggestedFileName(date: Date = .now, fileExtension: String = "png") -> String {
        "\(Branding.name) \(fileNameFormatter.string(from: date)).\(fileExtension)"
    }
}
