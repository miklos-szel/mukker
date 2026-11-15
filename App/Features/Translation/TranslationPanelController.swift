import AppKit
import SwiftUI

/// A borderless, non-activating panel for the translation result. Like the
/// popup's panel it can take key focus without the app having to win an
/// activation race, so Esc and text selection work the moment it appears.
final class TranslationPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        // Deliberately NOT `hidesOnDeactivate` — the same reason as `PopupPanel`:
        // activation is cooperative on macOS 14+ and may be denied, which would
        // make the panel vanish or never appear.
        isReleasedWhenClosed = false
    }

    /// Esc. The controller owns every close path.
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    /// The app has no Edit menu, so ⌘C/⌘A never resolve on their own — route
    /// them to whatever text view holds the selection.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
        case "a":
            if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
        case "w":
            onDismiss?()
            return true
        default:
            break
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Owns the translation panel: opens it at once on the hotkey (the answer takes
/// seconds, so the spinner is the feedback that the press registered), and
/// closes it on Esc, the Close button or a second press of the same hotkey.
///
/// Unlike the popup it does not close when it loses focus: the user reads the
/// result while working in another app, and pastes it there.
@MainActor
final class TranslationPanelController {
    static let shared = TranslationPanelController()

    static let size = NSSize(width: 520, height: 320)

    private var panel: TranslationPanel?
    private var debounce = RequestDebounce()

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows the panel and starts translating the text selected in the focused
    /// app, or the newest history entry when nothing is selected. A second
    /// press of the same language's hotkey while the panel is up closes it
    /// instead — the same toggle the popup hotkey has.
    ///
    /// The selection is read **before** `present()`: putting the panel up and
    /// activating moves focus, and with it the element whose selection we
    /// want — the same ordering rule as `ActiveAppTracker.captureFrontmost()`.
    func show(language: TranslationLanguage) {
        guard debounce.accept() else {
            Log.translate.debug("translate show ignored (duplicate request)")
            return
        }
        let service = TranslationService.shared
        if isVisible, service.state.language == language {
            close()
            return
        }
        let selection = service.readSelection()
        present()
        service.translateSelectionOrLatest(to: language, selection: selection)
    }

    /// Hides the panel and abandons a translation still in flight.
    func close() {
        TranslationService.shared.cancel()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        // Hand focus back to the app the user was in, so the translation can
        // be pasted straight away instead of into a windowless accessory app.
        if NSApp.isActive { ActiveAppTracker.shared.reactivate() }
        Log.translate.info("translate panel closed")
    }

    private func present() {
        if panel == nil {
            let panel = TranslationPanel(contentRect: NSRect(origin: .zero, size: Self.size))
            panel.onDismiss = { [weak self] in self?.close() }
            let root = TranslationView(onClose: { [weak self] in self?.close() })
            panel.contentView = NSHostingView(rootView: root)
            self.panel = panel
        }
        guard let panel else { return }
        // Before activating, or we would record ourselves as the target.
        if !panel.isVisible { ActiveAppTracker.shared.captureFrontmost() }
        // Re-centre only when it isn't already up, so a panel the user dragged
        // aside stays put while switching language.
        if !panel.isVisible { center(panel) }
        panel.level = .floating
        // Same order as the popup: put the panel up and key first, then ask to
        // activate. The panel is non-activating, so it takes key focus on its
        // own and nothing here depends on the activation being granted.
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Centred on the screen holding the mouse — where the user's attention
    /// is — falling back to the menu-bar display.
    private func center(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.screens.first else {
            panel.center()
            return
        }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: (frame.midX - size.width / 2).rounded(),
                                     y: (frame.midY - size.height / 2).rounded()))
    }
}
