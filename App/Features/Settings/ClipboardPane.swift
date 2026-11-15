import AppKit
import SwiftUI

/// Single scrolling pane for the clipboard + snippets side of the app: popup
/// size and appearance, History, Pasting, Forever history, Merging and Advanced
/// (ignored apps, max clip size) — no hidden sub-tabs. A grouped `Form` like
/// every other pane; the subpanes contribute their own `Section`s.
struct ClipboardPane: View {
    @ObservedObject private var settings = ClipboardSettings.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Window size") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.popupSizePercent, in: 0.3...0.9, step: 0.05) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("30%").font(.caption).foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text("90%").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 200)
                        .accessibilityLabel("Popup window size")
                        Text(sizeLabel)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 110, alignment: .trailing)
                    }
                }
            } header: {
                Text("Popup")
            } footer: {
                SettingsFootnote("Takes effect the next time the popup opens.")
            }

            Section {
                Toggle("Custom background color", isOn: $settings.popupCustomBackgroundEnabled)
                if settings.popupCustomBackgroundEnabled {
                    LabeledContent("Background color") {
                        BorderedColorWell(selection: $settings.popupBackgroundColor)
                    }
                }
                Toggle("Bezel around popup", isOn: $settings.popupBezelEnabled)
                if settings.popupBezelEnabled {
                    LabeledContent("Bezel color") {
                        BorderedColorWell(selection: $settings.popupBezelColor)
                    }
                    LabeledContent("Bezel width") {
                        HStack(spacing: 8) {
                            Slider(value: $settings.popupBezelWidth, in: 0...12, step: 1)
                                .frame(width: 150)
                                .accessibilityLabel("Bezel width")
                            Text("\(Int(settings.popupBezelWidth.rounded())) pt")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                SettingsFootnote("Takes effect the next time the popup opens.")
            }

            HistorySubpane()

            Section {
                Toggle(isOn: $settings.autoPasteEnabled) {
                    Text("Auto-paste into active app")
                    Text("Selecting an item sends ⌘V to the previously active app (requires "
                         + "Accessibility). When off, items are only copied to the clipboard.")
                }
            } header: {
                Text("Pasting")
            }

            Section {
                Toggle(isOn: $settings.foreverHistoryEnabled) {
                    Text("Keep deleted text forever")
                    Text("Before a text item is removed by retention or the item limit, it is "
                         + "saved as a .txt file in the folder below, so it's never truly lost.")
                }
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(settings.foreverHistoryDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseForeverDirectory)
                    }
                }
                .disabled(!settings.foreverHistoryEnabled)
            } header: {
                Text("Forever history")
            }

            MergingSubpane()

            AdvancedSubpane()
        }
        .formStyle(.grouped)
    }

    /// "60%  (892 × 522)" — the percentage and the size the popup opens at,
    /// from the same function the popup uses.
    private var sizeLabel: String {
        let pct = settings.popupSizePercent
        let visible = NSScreen.screens.first?.visibleFrame.size ?? PopupWindowController.baseSize
        let size = PopupWindowController.popupSize(percent: pct, visibleSize: visible)
        return "\(Int((pct * 100).rounded()))%  (\(Int(size.width)) × \(Int(size.height)))"
    }

    private func chooseForeverDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: settings.foreverHistoryDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.foreverHistoryDirectory = url.path
    }
}

/// Section footer text, styled like the other panes' footers.
struct SettingsFootnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A color well that stays visible at any color — the system well has no
/// border of its own in a grouped form, so a white color vanished into the row.
struct BorderedColorWell: View {
    @Binding var selection: Color

    var body: some View {
        ColorPicker("", selection: $selection, supportsOpacity: true)
            .labelsHidden()
    }
}
