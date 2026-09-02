import AppKit
import ApplicationServices
import Foundation

/// Which half of the screen a window is snapped to.
enum TileSlot: String, CaseIterable {
    case left, right, top, bottom
}

/// Snaps the frontmost window to a half of the screen it is currently on, via
/// the Accessibility API. The only thing in the app that talks to
/// `AXUIElement` — everything else goes through this service, the same way
/// `KeepAwakeService` solely owns IOKit power management.
///
/// Three details are load-bearing:
///
/// - **AX and Cocoa disagree about which way is up.** AX window geometry is
///   top-left-origin with Y growing downwards, anchored at the top-left of the
///   *primary* display; `NSScreen.frame`/`visibleFrame` is bottom-left-origin
///   with Y growing upwards. Every rect crossing that boundary goes through
///   `axRect(fromCocoa:primaryHeight:)` / `cocoaRect(fromAX:primaryHeight:)`,
///   and `primaryHeight` must come from `NSScreen.screens.first` (the physical
///   menu-bar display) — `NSScreen.main` follows keyboard focus and gives the
///   wrong answer the moment a second display is attached.
/// - **Position and size are written twice, in the order
///   position → size → position → size.** Many apps clamp a requested size
///   against the window's *current* screen and position, so a single pass lands
///   short whenever the move crosses displays or grows the window.
/// - **The messaging timeout is shortened to 0.5 s.** AX calls into a hung app
///   block for six seconds by default, which would freeze the main thread — and
///   with it the menu bar — on every press. The user asked for the move to be
///   immediate, so nothing on this path sleeps, animates or waits for an app to
///   activate.
@MainActor
final class WindowTiler {
    static let shared = WindowTiler()

    private let settings: WindowTilingSettings
    private let permissions: PermissionsService

    init(settings: WindowTilingSettings = .shared,
         permissions: PermissionsService = .shared) {
        self.settings = settings
        self.permissions = permissions
    }

    /// How long we wait on the target app before giving up on a single AX call.
    private static let messagingTimeout: Float = 0.5

    /// Read-back slack, in points, before we bother logging a mismatch.
    private static let placementTolerance: CGFloat = 2

    // MARK: - Geometry (pure, testable — no AX, no permissions, no windows)

    /// The half of `visibleFrame` a slot occupies, inset by `gap` on all four
    /// edges. Cocoa coordinates, so `.top` is the **higher** half (the `maxY`
    /// side). A gap wide enough to invert the rect clamps to zero rather than
    /// producing a negative size.
    nonisolated static func rect(for slot: TileSlot, in visibleFrame: CGRect, gap: CGFloat) -> CGRect {
        let half: CGRect
        switch slot {
        case .left:
            half = CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                          width: visibleFrame.width / 2, height: visibleFrame.height)
        case .right:
            half = CGRect(x: visibleFrame.midX, y: visibleFrame.minY,
                          width: visibleFrame.width / 2, height: visibleFrame.height)
        case .top:
            half = CGRect(x: visibleFrame.minX, y: visibleFrame.midY,
                          width: visibleFrame.width, height: visibleFrame.height / 2)
        case .bottom:
            half = CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                          width: visibleFrame.width, height: visibleFrame.height / 2)
        }
        let inset = max(0, gap)
        return CGRect(x: half.minX + inset,
                      y: half.minY + inset,
                      width: max(0, half.width - inset * 2),
                      height: max(0, half.height - inset * 2))
    }

    /// Bottom-left-origin Cocoa rect → top-left-origin AX rect.
    nonisolated static func axRect(fromCocoa rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// Top-left-origin AX rect → bottom-left-origin Cocoa rect. The inverse of
    /// `axRect(fromCocoa:primaryHeight:)`; the flip is its own inverse, so the
    /// arithmetic is identical — the two names exist so call sites say which
    /// space they are in.
    nonisolated static func cocoaRect(fromAX rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: primaryHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    // MARK: - Tiling

    /// Snaps the focused window to `slot` on the screen it is currently on.
    /// Silently does nothing (with a log line) when there is no usable window —
    /// a missing Accessibility grant is the one case that shows the user an
    /// alert, via `PermissionsService`.
    func tile(_ slot: TileSlot) {
        guard settings.isEnabled else { return }

        guard permissions.ensureAccessibility(
            reason: "\(Branding.name) needs Accessibility access to move windows."
        ) else { return }

        guard let window = focusedWindow() else {
            Log.window.info("tile: no focused window to move")
            return
        }

        if isFullScreen(window) {
            Log.window.info("tile: window is in native full screen — nothing to do")
            return
        }

        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            Log.window.error("tile: no screens available")
            return
        }

        guard let currentAX = frame(of: window) else {
            Log.window.info("tile: could not read the window's position/size")
            return
        }
        let current = Self.cocoaRect(fromAX: currentAX, primaryHeight: primaryHeight)

        guard let screen = screen(containing: current) else {
            Log.window.error("tile: could not resolve a target screen")
            return
        }

        let target = Self.rect(for: slot, in: screen.visibleFrame, gap: settings.gap)
        let targetAX = Self.axRect(fromCocoa: target, primaryHeight: primaryHeight)

        // Twice, deliberately — see the type's doc comment.
        setPosition(targetAX.origin, on: window)
        setSize(targetAX.size, on: window)
        setPosition(targetAX.origin, on: window)
        setSize(targetAX.size, on: window)

        if let landed = frame(of: window),
           abs(landed.minX - targetAX.minX) > Self.placementTolerance
            || abs(landed.minY - targetAX.minY) > Self.placementTolerance
            || abs(landed.width - targetAX.width) > Self.placementTolerance
            || abs(landed.height - targetAX.height) > Self.placementTolerance {
            // Not an error: fixed-size panels and apps with a minimum size
            // legitimately refuse part of the request.
            Log.window.info("tile: window landed at \(NSStringFromRect(landed), privacy: .public), wanted \(NSStringFromRect(targetAX), privacy: .public)")
        }
    }

    // MARK: - AX plumbing

    /// The window to move, resolved through the **system-wide** AX element rather
    /// than `NSWorkspace.frontmostApplication`. The workspace answer is not
    /// trustworthy from an `LSUIElement` accessory process — it can report
    /// `com.apple.loginwindow` while a normal app plainly has focus — whereas
    /// `kAXFocusedApplicationAttribute` is exactly the question we mean to ask.
    /// The workspace is kept only as a fallback.
    ///
    /// Windows belonging to us are skipped: our own popup is a non-activating
    /// panel, so pressing a tiling shortcut with it open should still move the
    /// app underneath.
    private func focusedWindow() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)

        if let app = copyElement(systemWide, kAXFocusedApplicationAttribute),
           !isOurs(app),
           let window = window(of: app) {
            return window
        }

        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != NSRunningApplication.current.bundleIdentifier else {
            return nil
        }
        let app = AXUIElementCreateApplication(frontmost.processIdentifier)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        return window(of: app)
    }

    /// The focused window of an app, else its main window, else its first —
    /// apps that never set `AXFocusedWindow` (some Electron and Java apps) still
    /// work through the fallbacks.
    private func window(of app: AXUIElement) -> AXUIElement? {
        if let window = copyElement(app, kAXFocusedWindowAttribute) { return window }
        if let window = copyElement(app, kAXMainWindowAttribute) { return window }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first
    }

    private func isOurs(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        return pid == ProcessInfo.processInfo.processIdentifier
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let result = value, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    /// `AXFullScreen` is not in the `kAX…` constants but is what every app that
    /// supports native full screen reports.
    private func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success,
              let flag = value as? Bool else { return false }
        return flag
    }

    /// The window's frame in AX (top-left-origin) coordinates.
    private func frame(of window: AXUIElement) -> CGRect? {
        guard let raw = copyAXValue(window, kAXPositionAttribute),
              let rawSize = copyAXValue(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(raw, .cgPoint, &origin),
              AXValueGetValue(rawSize, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func copyAXValue(_ window: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue)
    }

    private func setPosition(_ point: CGPoint, on window: AXUIElement) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ size: CGSize, on window: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    /// The screen the window is mostly on — by its centre, so a window straddling
    /// two displays tiles on the one holding the bulk of it.
    private func screen(containing rect: CGRect) -> NSScreen? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(centre) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
