import AppKit
import SwiftUI

/// Single scrolling pane for the clipboard + snippets side of the app: popup
/// size and appearance, History, Pasting, Forever History, Merging and Advanced
/// (Ignore Apps, Max Clip Size) — no hidden sub-tabs.
struct ClipboardPane: View {
    @ObservedObject private var settings = ClipboardSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Popup") {
                                    HStack {
                                        Text("Window size")
                                        Spacer()
                                        Text(sizeLabel)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                    Slider(value: $settings.popupSizePercent, in: 0.3...0.9, step: 0.05) {
                                        EmptyView()
                                    } minimumValueLabel: {
                                        Text("30%").font(.caption).foregroundStyle(.secondary)
                                    } maximumValueLabel: {
                                        Text("90%").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text("Takes effect the next time the popup opens.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                Divider()
                section("Appearance") {
                                    Toggle("Custom background color", isOn: $settings.popupCustomBackgroundEnabled)
                                    if settings.popupCustomBackgroundEnabled {
                                        ColorPicker("Background color", selection: $settings.popupBackgroundColor, supportsOpacity: true)
                                            .padding(.leading, 20)
                                    }

                                    Divider().padding(.vertical, 2)

                                    Toggle("Bezel around popup", isOn: $settings.popupBezelEnabled)
                                    if settings.popupBezelEnabled {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ColorPicker("Bezel color", selection: $settings.popupBezelColor, supportsOpacity: true)
                                            HStack {
                                                Text("Bezel width")
                                                Spacer()
                                                Text("\(Int(settings.popupBezelWidth.rounded())) pt")
                                                    .foregroundStyle(.secondary)
                                                    .monospacedDigit()
                                            }
                                            Slider(value: $settings.popupBezelWidth, in: 0...12, step: 1)
                                        }
                                        .padding(.leading, 20)
                                    }

                                    Text("Takes effect the next time the popup opens.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                Divider()
                section("History") { HistorySubpane() }
                Divider()
                section("Pasting") {
                    Toggle("Auto-paste into active app", isOn: $settings.autoPasteEnabled)
                    Text("When enabled, selecting an item sends ⌘V to the previously active app (requires Accessibility). When off, items are only copied to the clipboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                section("Forever History") {
                    Toggle("Keep deleted text forever", isOn: $settings.foreverHistoryEnabled)
                    Text("Before a text item is removed by retention or the max-items limit, save it as a .txt file in the folder below — so it's never truly lost.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(settings.foreverHistoryDirectory)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…", action: chooseForeverDirectory)
                    }
                    .disabled(!settings.foreverHistoryEnabled)
                }
                Divider()
                section("Merging") { MergingSubpane() }
                Divider()
                section("Advanced") { AdvancedSubpane() }
            }
            .padding()
        }
    }

    private var sizeLabel: String {
        let pct = settings.popupSizePercent
        let vf = NSScreen.screens.first?.visibleFrame.size ?? PopupWindowController.baseSize
        let aspect = PopupWindowController.baseSize.width / PopupWindowController.baseSize.height
        var w = vf.width * pct
        var h = w / aspect
        if h > vf.height * pct { h = vf.height * pct; w = h * aspect }
        return "\(Int((pct * 100).rounded()))%  (\(Int(w.rounded())) × \(Int(h.rounded())))"
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

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
