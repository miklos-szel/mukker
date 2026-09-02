import AppKit
import SwiftUI

/// Opens a window per capture, hosting the SwiftUI editor. Uses a titled window
/// with a transparent full-size-content title bar so the standard traffic-light
/// buttons sit over the toolbar (matching the editor's chrome-less look).
@MainActor
final class EditorWindowController: NSObject {
    static let shared = EditorWindowController()

    /// Retain open editor windows so they aren't deallocated.
    private var windows: [NSWindow] = []

    @discardableResult
    func open(image: CGImage, sourceScale: CGFloat) -> EditorViewModel {
        let viewModel = EditorViewModel(image: image, sourceScale: sourceScale)
        let host = NSHostingController(rootView: EditorView(viewModel: viewModel))

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Canvas drags create/move annotations; only the title-bar region moves the window.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false

        // Fit the initial window to the logical image size *plus* the configurable
        // canvas padding on every side, capped to the screen. Including the padding
        // gives the capture room to open centered with an equal transparent margin all
        // around (rather than hugging the image edges); bigger captures open bigger
        // windows. When the result exceeds the screen cap, `fitZoom` zooms the capture
        // down to fit. The width floor keeps the whole toolbar visible (it's wider than
        // a small capture); the height floor leaves room for toolbar + a usable canvas.
        let logical = viewModel.logicalSize
        let pad = viewModel.canvasPadding
        let visibleFrame = (NSScreen.main?.visibleFrame) ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxSize = CGSize(width: visibleFrame.width * 0.95, height: visibleFrame.height * 0.95)
        let contentSize = CGSize(
            width: min(max(logical.width + pad * 2, min(EditorMetrics.minWindowWidth, maxSize.width)),
                       maxSize.width),
            height: min(max(logical.height + pad * 2 + EditorMetrics.toolbarHeight,
                            EditorMetrics.minWindowHeight), maxSize.height)
        )
        window.setContentSize(contentSize)
        // Enforce the floor on the *window*, not just in SwiftUI: a `.frame(minWidth:)`
        // inside the hosting view doesn't stop a resize, so the toolbar could be
        // dragged narrow enough to clip its leading and trailing controls.
        window.contentMinSize = CGSize(width: EditorMetrics.minWindowWidth,
                                       height: EditorMetrics.minWindowHeight)
        Self.centerOnMainScreen(window)

        // Let the editor close its own window after copy/save (settings-driven).
        viewModel.requestClose = { [weak window] in
            window?.close()
        }
        // Release our retain on *any* close — traffic-light button included —
        // so closed editors (window + view model + images + undo history) don't
        // accumulate for the app's lifetime.
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: window)

        windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Keep first-responder off the toolbar buttons at launch (otherwise the
        // first button shows a focus ring and the canvas doesn't receive the tool
        // keyboard shortcuts). Route it to the hosting view so SwiftUI's
        // `defaultFocus` can hand it to the canvas.
        window.makeFirstResponder(host.view)
        return viewModel
    }

    /// Drops the closed window from the retain list. Windows always close on the
    /// main thread, so this runs on the main actor.
    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        windows.removeAll { $0 === window }
    }

    /// Centers `window` on the main display's visible frame (so the capture popup
    /// always opens on the main screen, never tucked under the menu bar).
    static func centerOnMainScreen(_ window: NSWindow) {
        guard let vf = NSScreen.main?.visibleFrame else { window.center(); return }
        var f = window.frame
        f.origin = CGPoint(x: vf.midX - f.width / 2, y: vf.midY - f.height / 2)
        window.setFrame(clamp(f, in: vf), display: false)
    }

    /// Grows the key (editor) window by `inset` points on every side and recenters
    /// it on its screen — used by the toolbar's Fit & center button.
    static func growAndCenterKeyWindow(by inset: CGFloat) {
        guard let window = NSApp.keyWindow else { return }
        let vf = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        var f = window.frame.insetBy(dx: -inset, dy: -inset)   // +inset on each side
        f.size.width = min(f.size.width, vf.width)
        f.size.height = min(f.size.height, vf.height)
        f.origin = CGPoint(x: vf.midX - f.width / 2, y: vf.midY - f.height / 2)
        window.setFrame(clamp(f, in: vf), display: true, animate: true)
    }

    /// Shifts `frame` fully inside `vf` without resizing it.
    private static func clamp(_ frame: CGRect, in vf: CGRect) -> CGRect {
        var f = frame
        if f.maxY > vf.maxY { f.origin.y = vf.maxY - f.height }
        if f.minY < vf.minY { f.origin.y = vf.minY }
        if f.maxX > vf.maxX { f.origin.x = vf.maxX - f.width }
        if f.minX < vf.minX { f.origin.x = vf.minX }
        return f
    }
}
