import AppKit
import SwiftUI

/// Everything the screen-capture side of the app owns: where captures go, what
/// happens right after one, the editor's auto-close behaviour, scrolling-capture
/// limits, annotation defaults and the editor's per-tool keys. The capture
/// *shortcuts* live in the shared Hotkeys pane, and "launch at login" in
/// Permissions, since both are app-wide rather than capture-specific.
struct CapturePane: View {
    @ObservedObject private var settings = CaptureSettings.shared

    var body: some View {
        Form {
            Section("Output") {
                LabeledContent("Screenshots folder") {
                    HStack(spacing: 8) {
                        Text(settings.saveDirectory.path)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Save format", selection: $settings.saveFormat) {
                    ForEach(SaveFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()

                Toggle("Downscale to 1× when saving", isOn: $settings.downscaleRetina)

                LabeledContent("Canvas padding") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.canvasPadding, in: 0...200).frame(width: 150)
                        Text("\(Int(settings.canvasPadding)) pt")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Behaviour") {
                Picker("After screenshot", selection: $settings.afterCapture) {
                    ForEach(AfterCapture.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()

                Toggle("Close editor after copying", isOn: $settings.closeAfterCopy)
                Toggle("Close editor after saving", isOn: $settings.closeAfterSave)
                Toggle("Esc copies to clipboard and closes editor", isOn: $settings.escCopiesAndCloses)
                    .help("Esc first cancels a crop, drops the selection and puts the "
                          + "pointer tool back; it copies and closes only from that state.")
                Toggle("Show magnifier loupe while selecting", isOn: $settings.showMagnifier)

#if DEBUG
                Toggle("Show debug menu items", isOn: $settings.enableDebugMenu)
#endif
            }

            Section("Scrolling capture") {
                LabeledContent("Max height") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.scrollMaxHeight, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        Text("px").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Speed") {
                    Slider(value: $settings.scrollSpeed, in: 0...1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Slower").font(.caption).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("Faster").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 220)
                    .accessibilityLabel("Scrolling speed")
                }
            }

            Section("Annotation defaults") {
                LabeledContent("Color") {
                    PaletteSwatches(index: $settings.defaultColorIndex)
                }
                LabeledContent("Text color") {
                    PaletteSwatches(index: $settings.defaultTextColorIndex)
                }
                LabeledContent("Line width") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.defaultLineWidth, in: 1...20).frame(width: 150)
                        Text("\(Int(settings.defaultLineWidth)) pt")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Text size") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.defaultTextSize, in: 10...96).frame(width: 150)
                        Text("\(Int(settings.defaultTextSize)) pt")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(Tool.allCases) { tool in
                    LabeledContent(tool.help) {
                        ToolKeyField(tool: tool, settings: settings)
                    }
                }
            } header: {
                Text("Editor tool keys")
            } footer: {
                Text("Single-letter keys used in the editor while no text field is "
                     + "active. Reusing a letter swaps it with the tool that had it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = url
        }
    }
}

/// A row of selectable color swatches bound to an index into `AnnotationStyle.palette`.
/// Renders the editor toolbar's `ColorSwatchRow`, so the two places that show the
/// palette can't drift apart in size, ring weight or hover behaviour again.
private struct PaletteSwatches: View {
    @Binding var index: Int

    var body: some View {
        ColorSwatchRow(selectedIndex: index, size: 18, spacing: 4) { i, _ in index = i }
    }
}

/// A one-letter field bound (via `EditorShortcuts`) to a tool's key. Reads/writes
/// live through `CaptureSettings`, so swaps reflect across rows immediately.
private struct ToolKeyField: View {
    let tool: Tool
    @ObservedObject var settings: CaptureSettings

    var body: some View {
        TextField("", text: Binding(
            get: { String(EditorShortcuts.effective(tool, settings)).uppercased() },
            set: { newValue in
                if let char = newValue.last { EditorShortcuts.assign(char, to: tool, settings) }
            }))
            .frame(width: 44)
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
    }
}
