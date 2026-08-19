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

    final class Coordinator {
        var parent: ShortcutRecorderField
        init(_ parent: ShortcutRecorderField) { self.parent = parent }
    }

    /// An `NSButton` that, while armed, captures the next key-down as a combo.
    final class RecorderButton: NSButton {
        var onRecord: ((KeyCombo) -> Void)?
        var combo: KeyCombo = KeyCombo(carbonKeyCode: 0) {
            didSet { if !recording { refreshTitle() } }
        }

        private var recording = false
        private var monitor: Any?

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

        @objc private func beginRecording() {
            guard !recording else { return }
            recording = true
            title = "Type shortcut…"
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                self?.capture(event)
                return nil   // swallow the event while recording
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
            combo = recorded
            onRecord?(recorded)
            stopRecording()
        }

        private func stopRecording() {
            recording = false
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            refreshTitle()
        }

        private func refreshTitle() {
            title = combo.carbonKeyCode == 0 ? "Record Shortcut" : combo.description
        }
    }
}
