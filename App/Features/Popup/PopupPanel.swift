import AppKit

/// A borderless, non-activating panel that hosts the popup UI.
final class PopupPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
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
        // Deliberately NOT `hidesOnDeactivate`: it ties the panel's visibility
        // to app activation, which on macOS 14+ is cooperative and can be
        // denied — a press of the hotkey would then show nothing at all. The
        // controller dismisses us on `onResignKey` instead.
        isReleasedWhenClosed = false
    }

    /// Called when the panel should close (Esc). The controller owns every
    /// close path so its own record of the popup's state stays in step.
    var onDismiss: (() -> Void)?

    /// Called when the panel loses key status, so the controller can decide
    /// whether that means the user clicked away.
    var onResignKey: (() -> Void)?

    /// Called when ⌘, is pressed while the popup is key. The popup is a
    /// non-activating panel, so the app menu's ⌘, shortcut never fires —
    /// we route it ourselves to open Settings.
    var onCommandComma: (() -> Void)?

    /// Called when ⌘C is pressed: copy the selected item without pasting.
    var onCommandC: (() -> Void)?

    /// Called when ⌘⇧V is pressed: paste the selected item as plain text.
    var onCommandShiftV: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.modifierFlags.contains(.shift) {
            if key == "v" { onCommandShiftV?(); return true }
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case ",":
            onCommandComma?()
            return true
        case "c":
            // With text selected in the search field, ⌘C copies that
            // selection; otherwise it copies the highlighted row.
            if let editor = activeFieldEditor, editor.selectedRange().length > 0 {
                editor.copy(nil)
                return true
            }
            onCommandC?()
            return true
        // The app has no Edit menu (LSUIElement + MenuBarExtra), so the
        // standard editing key equivalents never resolve — route them to the
        // search field's editor ourselves.
        case "v":
            if let editor = activeFieldEditor { editor.paste(nil); return true }
            return super.performKeyEquivalent(with: event)
        case "a":
            if let editor = activeFieldEditor { editor.selectAll(nil); return true }
            return super.performKeyEquivalent(with: event)
        case "x":
            if let editor = activeFieldEditor { editor.cut(nil); return true }
            return super.performKeyEquivalent(with: event)
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// The field editor currently editing the search field, if it has focus.
    private var activeFieldEditor: NSTextView? {
        guard let editor = firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor
    }
}
