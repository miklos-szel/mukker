import AppKit
import Foundation

/// Caches `NSImage` icons for app bundle identifiers so the popup can render
/// real source-app icons without paying the disk-lookup cost on every redraw.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()

    private var iconCache: [String: NSImage] = [:]
    private var nameCache: [String: String] = [:]

    /// Returns the icon for the given bundle id, or a generic fallback.
    func icon(forBundleID bundleID: String?) -> NSImage {
        if let id = bundleID, let cached = iconCache[id] {
            return cached
        }
        let image: NSImage
        if let id = bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSWorkspace.shared.icon(for: .data)
        }
        if let id = bundleID {
            iconCache[id] = image
        }
        return image
    }

    /// Returns the display name for the given bundle id, memoized. nil for empty/unknown ids.
    func appName(forBundleID bundleID: String?) -> String? {
        guard let id = bundleID, !id.isEmpty else { return nil }
        if let cached = nameCache[id] { return cached }
        let name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            name = url.deletingPathExtension().lastPathComponent
        } else {
            name = id
        }
        nameCache[id] = name
        return name
    }
}
