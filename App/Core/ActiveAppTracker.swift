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
    ///
    /// Under macOS 14 cooperative activation an app that is itself active has to
    /// yield before another one may take focus, or the `activate()` is simply
    /// ignored. Showing the popup no longer activates us, but anything that does
    /// (Settings, the capture editor, a modal alert) would otherwise leave the
    /// paste with nowhere to go.
    @MainActor
    func reactivate() {
        guard let app = lastActiveApp else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }
}
