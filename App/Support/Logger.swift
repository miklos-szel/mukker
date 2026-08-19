import Foundation
import OSLog

/// Unified log categories across both feature sets. View with e.g.
/// `log show --predicate 'subsystem == "com.sniptory.Sniptory"' --info --last 1m`.
enum Log {
    static let subsystem = Branding.bundleID

    // Shared
    static let app = Logger(subsystem: subsystem, category: "app")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")

    // Clipboard / snippets
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let snippets = Logger(subsystem: subsystem, category: "snippets")
    static let db = Logger(subsystem: subsystem, category: "db")
    static let paste = Logger(subsystem: subsystem, category: "paste")

    // Capture / editor
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let editor = Logger(subsystem: subsystem, category: "editor")
    static let export = Logger(subsystem: subsystem, category: "export")
}
