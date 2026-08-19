import AppKit

/// A borderless, transparent panel covering one display, hosting the selection view.
final class SelectionOverlayWindow: NSPanel {
    init(capture: DisplayCapture, showMagnifier: Bool = false) {
        super.init(
            contentRect: capture.screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // No fade-in/out when the dimming overlay appears or dismisses.
        animationBehavior = .none
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        contentView = SelectionOverlayView(capture: capture, showMagnifier: showMagnifier)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Presents selection overlays across every display and resolves the first
/// completed (or cancelled) selection.
@MainActor
final class SelectionOverlayController {
    private var windows: [SelectionOverlayWindow] = []
    private var completion: ((DisplayCapture, CGRect)?) -> Void = { _ in }
    private var captureFor: [ObjectIdentifier: DisplayCapture] = [:]

    /// Shows one overlay per display. `completion` receives the chosen display
    /// capture plus the selected rect in image pixels, or nil if cancelled.
    func present(captures: [DisplayCapture],
                 completion: @escaping ((DisplayCapture, CGRect)?) -> Void) {
        self.completion = completion
        let showMagnifier = CaptureSettings.shared.showMagnifier
        for capture in captures {
            let window = SelectionOverlayWindow(capture: capture, showMagnifier: showMagnifier)
            captureFor[ObjectIdentifier(window)] = capture
            if let view = window.contentView as? SelectionOverlayView {
                view.onComplete = { [weak self, weak window] rect in
                    guard let self, let window,
                          let cap = self.captureFor[ObjectIdentifier(window)] else { return }
                    if let rect { self.finish((cap, rect)) } else { self.finish(nil) }
                }
            }
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
    }

    private func finish(_ result: (DisplayCapture, CGRect)?) {
        let done = completion
        completion = { _ in }
        dismiss()
        done(result)
    }

    private func dismiss() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        captureFor.removeAll()
    }
}
