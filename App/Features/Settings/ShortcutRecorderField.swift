import AppKit
import HotKey
import SwiftUI

/// A click-to-record key-combo field. Clicking it listens for the next key
/// press (with modifiers) and writes the resulting `KeyCombo` to the binding.
struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var combo: KeyCombo

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onRecord = { context.coordinator.parent.combo = $0 }
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        context.coordinator.parent = self
        button.combo = combo
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Whether `combo` may become a global hotkey. A global hotkey swallows its
    /// key in every app, so it needs at least one of ⌘, ⌃ or ⌥ — a plain letter
    /// (or ⇧ + letter) would stop the user typing it anywhere. F1–F20 are the
    /// exception: they type nothing, so they are allowed bare.
    nonisolated static func isAcceptable(_ combo: KeyCombo) -> Bool {
        guard let key = combo.key else { return false }
        if !combo.modifiers.isDisjoint(with: [.command, .control, .option]) { return true }
        switch key {
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
             .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            return true
        default:
            return false
        }
    }

    final class Coordinator {
        var parent: ShortcutRecorderField
        init(_ parent: ShortcutRecorderField) { self.parent = parent }
    }

    /// An `NSButton` that, while armed, captures the next key-down as a combo.
    ///
    /// While recording it holds an app-wide local key monitor that swallows every
    /// key-down, so recording must end whenever the field stops being where the
    /// user is typing: the view leaving its window, the window resigning key, or
    /// the button going away — otherwise the monitor outlives the field and eats
    /// keystrokes all over the app.
    final class RecorderButton: NSButton {
        var onRecord: ((KeyCombo) -> Void)?
        var combo: KeyCombo = KeyCombo(carbonKeyCode: 0) {
            didSet { if !recording { refreshTitle() } }
        }

        private var recording = false
        private var monitor: Any?
        private var resignKeyObserver: NSObjectProtocol?

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(beginRecording)
            refreshTitle()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopRecording() }
        }

        @objc private func beginRecording() {
            guard !recording else { return }
            recording = true
            title = "Type shortcut…"
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }
                self.capture(event)
                return nil   // swallow the event while recording
            }
            if let window {
                resignKeyObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stopRecording() }
                }
            }
        }

        private func capture(_ event: NSEvent) {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Escape with no modifiers cancels without changing the combo.
            if event.keyCode == 53 && modifiers.isEmpty {
                stopRecording()
                return
            }
            let recorded = KeyCombo(carbonKeyCode: UInt32(event.keyCode),
                                    carbonModifiers: modifiers.carbonFlags)
            // A combo that would hijack ordinary typing is not saved; keep
            // listening so the user can add a modifier (or press Esc).
            guard ShortcutRecorderField.isAcceptable(recorded) else {
                NSSound.beep()
                title = "Add ⌘, ⌃ or ⌥…"
                return
            }
            combo = recorded
            onRecord?(recorded)
            stopRecording()
        }

        private func stopRecording() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
            resignKeyObserver = nil
            guard recording else { return }
            recording = false
            refreshTitle()
        }

        private func refreshTitle() {
            title = combo.carbonKeyCode == 0 ? "Record Shortcut" : combo.description
        }
    }
}
