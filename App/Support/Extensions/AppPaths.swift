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
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: privateDirectoryAttributes)
        return dir
    }

    static var databaseURL: URL {
        supportDirectory.appendingPathComponent(Branding.databaseFileName)
    }

    static var imagesDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: privateDirectoryAttributes)
        return dir
    }

    static var richTextDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("richtext", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: privateDirectoryAttributes)
        return dir
    }

    /// Downloaded speech-to-text models (Dictation). Large files, but only a
    /// handful, so the launch-time permission walk stays cheap.
    static var modelsDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: privateDirectoryAttributes)
        return dir
    }

    // MARK: - Permissions
    //
    // Clipboard history can hold anything the user ever copied, so the support
    // folder is owner-only: directories 0700, the database and sidecar files 0600.

    static let privateDirectoryPermissions: Int = 0o700
    static let privateFilePermissions: Int = 0o600

    private static var privateDirectoryAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: privateDirectoryPermissions]
    }

    /// Writes a sidecar file (image PNG / RTF) and makes it owner-only. Not
    /// `.atomic`: an atomic write goes through a temporary file, which the launch
    /// orphan sweep could see and delete mid-write.
    static func writePrivateFile(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: privateFilePermissions],
                                              ofItemAtPath: url.path)
    }

    /// Tightens an existing tree (folders made by older builds were 0755, files
    /// 0644): directories to 0700, regular files — the SQLite file, its `-wal`/`-shm`
    /// and every sidecar — to 0600. Only items whose mode differs are touched, so a
    /// repeat run is a cheap walk. Blocking file I/O: call it off the main thread.
    /// Returns the number of items changed.
    @discardableResult
    static func tightenPermissions(under root: URL) -> Int {
        let fm = FileManager.default
        var changed = 0
        func apply(_ url: URL, isDirectory: Bool) {
            let wanted = isDirectory ? privateDirectoryPermissions : privateFilePermissions
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let current = (attrs[.posixPermissions] as? NSNumber)?.intValue,
                  current & 0o777 != wanted else { return }
            if (try? fm.setAttributes([.posixPermissions: wanted], ofItemAtPath: url.path)) != nil {
                changed += 1
            }
        }
        apply(root, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { return changed }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                apply(url, isDirectory: true)
            } else if values.isRegularFile == true {
                apply(url, isDirectory: false)
            }
        }
        return changed
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

    /// A timestamped file name like "Mukker 2026-05-29 at 09.41.12.png".
    static func suggestedFileName(date: Date = .now, fileExtension: String = "png") -> String {
        "\(Branding.name) \(fileNameFormatter.string(from: date)).\(fileExtension)"
    }
}
