import SwiftUI

/// The window-tiling side of the app: the master switch, the four global
/// shortcuts and the gap between tiled windows.
///
/// The shortcuts live here rather than in the shared `HotkeysPane` so the whole
/// feature is configurable from one place — the switch above them is what
/// decides whether they are registered at all. The Accessibility grant tiling
/// needs is *not* duplicated here: `PermissionsPane` is the single place every
/// permission is granted and its status shown.
struct WindowTilingPane: View {
    @ObservedObject private var settings = WindowTilingSettings.shared
    @ObservedObject private var shortcuts = ShortcutSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable window tiling", isOn: $settings.isEnabled)
            } header: {
                Text("Window Tiling")
            } footer: {
                Text("Snaps the frontmost window to half of the screen it is on, filling "
                     + "the space between the menu bar and the Dock. Moving windows needs "
                     + "Accessibility access — the same permission \(Branding.name) uses "
                     + "to paste; grant it under Settings → Permissions. Switching tiling "
                     + "off releases the shortcuts for other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Left half") {
                    ShortcutRecorderField(combo: $shortcuts.tileLeftCombo).frame(width: 160)
                }
                LabeledContent("Right half") {
                    ShortcutRecorderField(combo: $shortcuts.tileRightCombo).frame(width: 160)
                }
                LabeledContent("Top half") {
                    ShortcutRecorderField(combo: $shortcuts.tileTopCombo).frame(width: 160)
                }
                LabeledContent("Bottom half") {
                    ShortcutRecorderField(combo: $shortcuts.tileBottomCombo).frame(width: 160)
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Click a shortcut, then press the new key combination (Esc cancels). "
                     + "They work even when \(Branding.name) isn't focused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.isEnabled)

            Section {
                LabeledContent("Gap") {
                    HStack(spacing: 8) {
                        Text("\(Int(settings.gap)) pt").monospacedDigit()
                        Stepper("", value: $settings.gap,
                                in: 0...WindowTilingSettings.maximumGap, step: 2)
                            .labelsHidden()
                    }
                }
            } header: {
                Text("Layout")
            } footer: {
                Text("Inset on every edge of a tiled window, so two windows side by side "
                     + "end up twice this far apart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.isEnabled)
        }
        .formStyle(.grouped)
    }
}
