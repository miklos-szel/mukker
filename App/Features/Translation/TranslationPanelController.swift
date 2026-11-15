import AppKit
import Combine
import SwiftUI

/// A borderless, non-activating panel for the translation result. Like the
/// popup's panel it can take key focus without the app having to win an
/// activation race, so Esc and text selection work the moment it appears.
final class TranslationPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // `.resizable` on a borderless panel gives it edge/corner resizing
            // without a title bar.
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
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

    /// ⌘W and the Close button: always close.
    var onDismiss: (() -> Void)?
    /// Esc: the controller decides (it keeps an edited source on screen).
    var onEscape: (() -> Void)?
    /// ⌘↩: translate the source field again.
    var onSubmit: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc is taken here, before the source field sees it — an `NSTextView`
    /// turns Esc into `complete:` and it would never reach `cancelOperation`.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53, flags.isEmpty {
                onEscape?()
                return
            }
            // ⌘↩ likewise: a SwiftUI button shortcut fires *and* lets the
            // text view insert a newline, which would read as an edit.
            if event.keyCode == 36 || event.keyCode == 76, flags == .command {
                onSubmit?()
                return
            }
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// The app has no Edit menu, so the standard editing shortcuts never
    /// resolve on their own — route them to whatever text view has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        let shifted = flags.contains(.shift)
        let action: Selector?
        switch (event.charactersIgnoringModifiers?.lowercased(), shifted) {
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("a", false): action = #selector(NSText.selectAll(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        case ("w", false):
            onDismiss?()
            return true
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Owns the translation panel: opens it at once on the hotkey (the answer takes
/// seconds, so the spinner is the feedback that the press registered), and
/// closes it on Esc, ⌘W, the Close button or a second press of the same
/// hotkey — except that Esc and the hotkey leave it up while the source field
/// holds text the user typed and hasn't translated yet.
///
/// Unlike the popup it does not close when it loses focus: the user reads the
/// result while working in another app, and pastes it there. Its size comes
/// from `TranslationSettings` (applied live); where the user drags it is
/// remembered and reused.
@MainActor
final class TranslationPanelController {
    static let shared = TranslationPanelController()

    private var panel: TranslationPanel?
    private var debounce = RequestDebounce()
    private var observers: [AnyCancellable] = []
    /// Set while we move the panel ourselves, so only the user's drags are
    /// remembered as its position.
    private var isPlacing = false

    private var settings: TranslationSettings { .shared }

    private var size: NSSize {
        NSSize(width: settings.panelWidth, height: settings.panelHeight)
    }

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
        if isVisible {
            // Typed text wins over everything: the hotkey translates it.
            if service.isDraftEdited {
                present()
                service.translateDraft(to: language)
                return
            }
            if service.state.language == language {
                close()
                return
            }
            // With the panel focused there is no selection elsewhere to read,
            // and history's newest entry is by now the translation itself —
            // so the other language's hotkey re-sends what is shown.
            if panel?.isKeyWindow == true {
                service.translateDraft(to: language)
                return
            }
        }
        let read = service.readSelection()
        present()
        service.translate(read, to: language)
    }

    /// Esc: closes, unless the source field holds untranslated edits — those
    /// would be lost, so it takes ⌘W or the Close button to discard them.
    func escape() {
        if TranslationService.shared.isDraftEdited {
            NSSound.beep()
            return
        }
        close()
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
        if panel == nil { makePanel() }
        guard let panel else { return }
        if !panel.isVisible {
            // Before activating, or we would record ourselves as the target.
            ActiveAppTracker.shared.captureFrontmost()
            place(panel)
        }
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

    private func makePanel() {
        let panel = TranslationPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.onDismiss = { [weak self] in self?.close() }
        panel.onEscape = { [weak self] in self?.escape() }
        panel.onSubmit = {
            let service = TranslationService.shared
            guard !service.state.isRunning else { return }
            service.translateDraft(to: service.state.language ?? .english)
        }
        let root = TranslationView(onClose: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: root)
        // The window's size is ours (settings + edge drags); don't let the
        // hosting view pin it to the SwiftUI content's size.
        host.sizingOptions = []
        panel.contentView = host
        panel.contentMinSize = NSSize(width: TranslationSettings.panelWidthRange.lowerBound,
                                      height: TranslationSettings.panelHeightRange.lowerBound)
        panel.contentMaxSize = NSSize(width: TranslationSettings.panelWidthRange.upperBound,
                                      height: TranslationSettings.panelHeightRange.upperBound)
        self.panel = panel

        // An edge drag is a size change made in the panel: store it, so the
        // Settings sliders follow and the next open uses it.
        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: panel)
            .sink { [weak self, weak panel] _ in
                guard let self, let panel, !self.isPlacing else { return }
                let size = panel.frame.size
                if self.settings.panelWidth != size.width { self.settings.panelWidth = size.width }
                if self.settings.panelHeight != size.height { self.settings.panelHeight = size.height }
            }
            .store(in: &observers)

        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self, weak panel] _ in
                guard let self, let panel, !self.isPlacing else { return }
                self.settings.panelTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            }
            .store(in: &observers)
        // `@Published` emits before the value is stored: deliver on the next
        // run-loop pass and read the settings then.
        settings.$panelWidth.combineLatest(settings.$panelHeight)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resizeKeepingTopLeft() }
            .store(in: &observers)
    }

    /// The remembered spot when it is still on a screen, else centred on the
    /// screen holding the mouse — where the user's attention is.
    private func place(_ panel: NSPanel) {
        isPlacing = true
        defer { isPlacing = false }
        let size = size
        if let topLeft = settings.panelTopLeft {
            let frame = NSRect(x: topLeft.x, y: topLeft.y - size.height,
                               width: size.width, height: size.height)
            // At least the title strip must be reachable to drag it back.
            let strip = NSRect(x: frame.minX, y: frame.maxY - 40, width: frame.width, height: 40)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(strip) }) {
                panel.setFrame(frame, display: false)
                return
            }
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.screens.first else {
            panel.setContentSize(size)
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: (visible.midX - size.width / 2).rounded(),
                              y: (visible.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height),
                       display: false)
    }

    /// A size change from Settings, applied to an open panel without moving
    /// its top edge.
    private func resizeKeepingTopLeft() {
        guard let panel, panel.isVisible, panel.frame.size != size else { return }
        isPlacing = true
        defer { isPlacing = false }
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height,
                              width: size.width, height: size.height),
                       display: true)
    }
}
