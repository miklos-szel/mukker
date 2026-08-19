import AppKit
import ApplicationServices
import CoreGraphics

/// The single owner of every macOS privacy permission the app touches.
///
/// - **Screen Recording** (TCC): required by ScreenCaptureKit — without it
///   `SCShareableContent.current` fails and captures produce nothing.
/// - **Accessibility** (AX trust): required by three independent subsystems —
///   pasting (synthetic ⌘V), the fast-append global ⌘C monitor, and scrolling
///   capture (synthetic scroll events). One grant covers all three.
///
/// Status is read live (`AXIsProcessTrusted` / `CGPreflightScreenCaptureAccess`)
/// rather than cached: the user can revoke either one in System Settings at any
/// time, behind the app's back.
@MainActor
final class PermissionsService {
    static let shared = PermissionsService()

    // MARK: - Screen Recording

    /// Non-prompting check of the current Screen Recording authorization.
    var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt the first time; afterwards the user must grant
    /// it manually in System Settings. Returns the (possibly still-false) status.
    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Opens System Settings → Privacy & Security → Screen Recording.
    func openScreenRecordingSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Ensures Screen Recording access, prompting/guiding as needed. Returns the
    /// (possibly still-false) status so callers can bail out.
    @discardableResult
    func ensureScreenRecording() -> Bool {
        if hasScreenRecordingPermission { return true }
        // First run triggers the system prompt; if still denied, guide to Settings.
        if requestScreenRecordingPermission() { return true }
        presentScreenRecordingDeniedAlert()
        return false
    }

    // MARK: - Accessibility

    /// Non-prompting check of Accessibility (AX) trust.
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts for Accessibility if not yet trusted. The system shows its own
    /// prompt; the user must grant it in System Settings and may need to relaunch.
    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Ensures Accessibility access, prompting/guiding as needed. Returns the
    /// (possibly still-false) status so callers can bail out.
    @discardableResult
    func ensureAccessibility(reason: String = "") -> Bool {
        if hasAccessibilityPermission { return true }
        if requestAccessibilityPermission() { return true }
        presentAccessibilityDeniedAlert(reason: reason)
        return false
    }

    // MARK: - Alerts

    private func presentAccessibilityDeniedAlert(reason: String) {
        let why = reason.isEmpty
            ? "\(Branding.name) needs Accessibility access for this."
            : reason
        presentAlert(title: "Accessibility permission needed",
                     body: "\(why) Enable \(Branding.name) under Privacy & Security → "
                         + "Accessibility, then try again.",
                     openSettings: openAccessibilitySettings)
    }

    /// Shows an alert explaining the missing permission with a shortcut to Settings.
    func presentScreenRecordingDeniedAlert() {
        presentAlert(title: "Screen Recording permission needed",
                     body: "\(Branding.name) needs Screen Recording access to capture your "
                         + "screen. Enable it in System Settings, then try again.",
                     openSettings: openScreenRecordingSettings)
    }

    private func presentAlert(title: String, body: String, openSettings: () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSettings()
        }
    }
}
