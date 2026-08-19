import AppKit
import Foundation

/// Tracks the frontmost application so that after we present the popup,
/// we can paste back into whatever the user was working in.
final class ActiveAppTracker {
    static let shared = ActiveAppTracker()

    private(set) var lastActiveApp: NSRunningApplication?

    /// Capture the current frontmost app. Call this BEFORE bringing up the popup.
    func captureFrontmost() {
        let me = NSRunningApplication.current.bundleIdentifier
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != me {
            lastActiveApp = app
        }
    }

    /// Re-activate the previously captured app.
    func reactivate() {
        lastActiveApp?.activate()
    }
}
