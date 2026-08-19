import SwiftUI

struct MergingSubpane: View {
    @ObservedObject private var settings = ClipboardSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Fast append selected text", isOn: $settings.fastAppendEnabled)
            Text("Hold ⌘ and double tap C to append the currently selected clipboard item to the previously copied text in the Clipboard History.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Group {
                Toggle("Place merged text back into macOS clipboard",
                       isOn: $settings.fastAppendBackToPasteboard)
                Text("By placing the merged text back into the macOS clipboard, you can paste with ⌘V without having to open \(Branding.name)'s Clipboard History.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Separator", selection: $settings.appendSeparator) {
                    ForEach(AppendSeparator.allCases) { sep in
                        Text("Separate appended item with \(sep.label.lowercased())").tag(sep)
                    }
                }
                .labelsHidden()
                .fixedSize()

                Toggle("Play a sound when appending", isOn: $settings.playAppendSound)
                Text("Plays the system 'Purr' sound when an item is successfully appended.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 20)
            .disabled(!settings.fastAppendEnabled)
        }
    }
}
