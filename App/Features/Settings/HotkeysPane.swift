import SwiftUI

/// Every global shortcut in one place — the popup from the clipboard/snippets
/// side and the three capture shortcuts. All four are backed by
/// `ShortcutSettings`, so a change here re-registers the live hotkey immediately.
struct HotkeysPane: View {
    @ObservedObject private var shortcuts = ShortcutSettings.shared

    var body: some View {
        Form {
            Section("Clipboard & Snippets") {
                LabeledContent("Show popup") {
                    ShortcutRecorderField(combo: $shortcuts.popupCombo).frame(width: 160)
                }
            }

            Section("Capture") {
                LabeledContent("Area screenshot") {
                    ShortcutRecorderField(combo: $shortcuts.areaCombo).frame(width: 160)
                }
                LabeledContent("Fullscreen screenshot") {
                    ShortcutRecorderField(combo: $shortcuts.fullscreenCombo).frame(width: 160)
                }
                LabeledContent("Scrolling capture") {
                    ShortcutRecorderField(combo: $shortcuts.scrollCombo).frame(width: 160)
                }
            }

            Section {
                HStack {
                    Text("Click a shortcut, then press the new key combination "
                         + "(Esc cancels). Global shortcuts work even when "
                         + "\(Branding.name) isn't focused.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset All") { shortcuts.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
