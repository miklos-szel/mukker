import AppKit
import SwiftUI

/// Coalesces duplicate show/toggle requests that arrive within a short window.
///
/// ⌘E reaches us twice when the app is active: once from the Carbon global
/// hotkey and once from the menu-bar item's key equivalent. Without this, the
/// two deliveries can cancel each other out (show, then toggle-closed) and the
/// press looks like it did nothing.
struct RequestDebounce {
    private var last: Date = .distantPast

    /// True if the request should be acted on; false if it duplicates one we
    /// just handled.
    mutating func accept(_ now: Date = Date(), window: TimeInterval = 0.2) -> Bool {
        guard now.timeIntervalSince(last) >= window else { return false }
        last = now
        return true
    }
}

@MainActor
final class PopupWindowController {
    static let shared = PopupWindowController()

    private var panel: PopupPanel?
    private let viewModel = PopupViewModel()
    private var keyObserver: NSObjectProtocol?
    private var didPromptForAX = false
    /// Our own record of intent, so a hide can never be undone by the
    /// re-assert in `show()` and so every close path runs through `hide()`.
    private var isShown = false
    private var debounce = RequestDebounce()

    /// Set by the App layer (AppDelegate) so the popup can open Settings on ⌘,.
    var onRequestSettings: (() -> Void)?

    init() {
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleWindowDidBecomeKey(note)
            }
        }
    }

    deinit {
        if let observer = keyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// The popup only counts as open when it is actually the focused window.
    /// A panel that is `isVisible` but not key is one the user cannot see or
    /// type into, and pressing the hotkey then must re-show it — not close it.
    private var isPopupFocused: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.isKeyWindow
    }

    func toggle() {
        guard debounce.accept() else {
            Log.hotkey.debug("popup toggle ignored (duplicate request)")
            return
        }
        if isPopupFocused { hide() } else { present() }
    }

    func show() {
        guard debounce.accept() else {
            Log.hotkey.debug("popup show ignored (duplicate request)")
            return
        }
        present()
    }

    /// Builds the panel if needed, then puts it on screen. Callers debounce.
    private func present() {
        ActiveAppTracker.shared.captureFrontmost()
        // Each open starts fresh: top-level, empty query, first row selected.
        viewModel.reset()

        // Prompt for Accessibility once per launch if it's missing — without it
        // we can only copy, not auto-paste.
        if !didPromptForAX, !PermissionsService.shared.hasAccessibilityPermission {
            didPromptForAX = true
            _ = PermissionsService.shared.requestAccessibilityPermission()
        }

        if panel == nil {
            viewModel.onRequestClose = { [weak self] in
                self?.hide()
            }
            let rect = NSRect(origin: .zero, size: currentSize)
            let panel = PopupPanel(contentRect: rect)
            panel.onDismiss = { [weak self] in
                self?.hide()
            }
            panel.onResignKey = { [weak self] in
                self?.handlePanelResignedKey()
            }
            panel.onCommandComma = { [weak self] in
                self?.hide()
                self?.onRequestSettings?()
            }
            panel.onCommandC = { [weak self] in
                self?.viewModel.copySelection()
            }
            panel.onCommandShiftV = { [weak self] in
                self?.viewModel.pastePlainSelection()
            }
            let root = PopupRootView()
                .environmentObject(viewModel)
            panel.contentView = NSHostingView(rootView: root)
            self.panel = panel
        }
        guard let panel else { return }
        // The panel is reused across shows; re-apply the size so a changed
        // popup-size setting takes effect on the next open without a restart.
        let size = currentSize
        if panel.frame.size != size {
            panel.setContentSize(size)
        }
        applyAppearance(to: panel)
        centerOnScreen(panel)
        panel.level = .floating
        isShown = true
        // Order in first, then ask to activate: the panel is non-activating, so
        // it can take key focus on its own. Activation on macOS 14+ is
        // cooperative and may be deferred or denied, and nothing here may
        // depend on it having happened.
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Log.hotkey.debug("popup show: visible=\(panel.isVisible) key=\(panel.isKeyWindow) active=\(NSApp.isActive)")
        // Guarantee the search field has focus and the selection is back at the top
        // on every show (the panel + view model are reused). Done after the window is
        // visible so we win any cache refresh that was queued before the show.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel else { return }
            // Re-assert once: if activation raced us and the panel did not end
            // up front and key, put it there. Guarded by `isShown` so an
            // intentional close in the meantime wins.
            if isShown, !panel.isVisible || !panel.isKeyWindow {
                Log.hotkey.debug("popup show: re-asserting front (visible=\(panel.isVisible) key=\(panel.isKeyWindow))")
                panel.makeKeyAndOrderFront(nil)
            }
            if let field = Self.firstTextField(in: panel.contentView) {
                panel.makeFirstResponder(field)
            }
            self.viewModel.selectFirstRow()
        }
    }

    /// The single close path — every dismissal routes through here so `isShown`
    /// stays in step with the window.
    private func hide() {
        isShown = false
        panel?.orderOut(nil)
    }

    /// Reference geometry — defines the popup's **aspect ratio** and the
    /// list/preview split, not absolute pixels. The actual size is a percentage
    /// of the screen (see `popupSize(for:)`), fitted to this aspect ratio.
    static let baseSize = NSSize(width: 820, height: 480)
    /// Width of the results list at the reference geometry; the preview pane
    /// takes the rest.
    static let baseListWidth: CGFloat = 380
    /// Results-list share of the popup width (preview pane takes the rest).
    static let listWidthFraction = baseListWidth / baseSize.width   // ≈0.463

    /// Popup size for the primary screen, falling back to `baseSize` when no
    /// screen is available (e.g. headless test contexts).
    private var currentSize: NSSize {
        guard let screen = NSScreen.screens.first else { return Self.baseSize }
        return popupSize(for: screen)
    }

    /// Fit the base aspect ratio inside `popupSizePercent` of the screen's
    /// `visibleFrame` (respecting menu bar / dock / notch).
    private func popupSize(for screen: NSScreen) -> NSSize {
        let pct = ClipboardSettings.shared.popupSizePercent
        let vf = screen.visibleFrame
        let aspect = Self.baseSize.width / Self.baseSize.height
        var w = vf.width * pct
        var h = w / aspect
        let maxH = vf.height * pct
        if h > maxH { h = maxH; w = h * aspect }
        return NSSize(width: w.rounded(), height: h.rounded())
    }

    private static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField { return field }
        for sub in view.subviews {
            if let found = firstTextField(in: sub) { return found }
        }
        return nil
    }

    /// When the user picks a custom popup background, force the panel's
    /// appearance to match the background's luminance so the dynamic
    /// `PopupTheme` text/divider colors resolve with proper contrast (e.g. a
    /// white background gets dark text even while the system is in dark mode).
    /// With no custom background, follow the system appearance (`nil`).
    private func applyAppearance(to panel: NSPanel) {
        let settings = ClipboardSettings.shared
        guard settings.popupCustomBackgroundEnabled else {
            panel.appearance = nil
            return
        }
        let light = settings.popupBackgroundColor.isLight
        panel.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    }

    private func centerOnScreen(_ panel: NSPanel) {
        // Always the physical primary display (origin 0,0 / menu-bar screen),
        // not NSScreen.main which follows keyboard focus across displays.
        guard let screen = NSScreen.screens.first else {
            panel.center()
            return
        }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    /// Another window of ours taking focus means the popup is unusable — close
    /// it rather than leaving it behind the new window, where it would still
    /// count as visible and swallow the next hotkey press.
    private func handleWindowDidBecomeKey(_ note: Notification) {
        guard let panel, panel.isVisible else { return }
        guard let window = note.object as? NSWindow else { return }
        if window === panel {
            panel.level = .floating
            return
        }
        // A modal alert (e.g. "New Collection" from the preview pane, or a
        // permissions alert) is layered over the popup on purpose and the flow
        // returns to it afterwards.
        guard NSApp.modalWindow == nil else { return }
        Log.hotkey.debug("popup hidden: another window became key")
        hide()
    }

    /// Clicking outside the app dismisses the popup. This used to be AppKit's
    /// `hidesOnDeactivate`, which also refused to show the panel while the app
    /// was inactive — the reason a press could vanish entirely.
    private func handlePanelResignedKey() {
        // Let the new key window settle before deciding.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            guard NSApp.modalWindow == nil else { return }
            // Another of our windows took focus — `handleWindowDidBecomeKey`
            // owns that case.
            if let key = NSApp.keyWindow, key !== panel { return }
            self.hide()
        }
    }
}
