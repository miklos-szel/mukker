import AppKit
import SwiftUI

@MainActor
final class PopupWindowController {
    static let shared = PopupWindowController()

    private var panel: PopupPanel?
    private let viewModel = PopupViewModel()
    private var keyObserver: NSObjectProtocol?
    private var didPromptForAX = false

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

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
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
                self?.panel?.orderOut(nil)
            }
            let rect = NSRect(origin: .zero, size: currentSize)
            let panel = PopupPanel(contentRect: rect)
            panel.onCommandComma = { [weak self] in
                self?.panel?.orderOut(nil)
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
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Guarantee the search field has focus and the selection is back at the top
        // on every show (the panel + view model are reused). Done after the window is
        // visible so we win any cache refresh that was queued before the show.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel else { return }
            if let field = Self.firstTextField(in: panel.contentView) {
                panel.makeFirstResponder(field)
            }
            self.viewModel.selectFirstRow()
        }
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

    private func handleWindowDidBecomeKey(_ note: Notification) {
        guard let panel = panel else { return }
        guard let window = note.object as? NSWindow else { return }
        if window === panel {
            panel.level = .floating
        } else {
            panel.level = .normal
            panel.orderBack(nil)
        }
    }
}
