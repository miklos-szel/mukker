import SwiftUI

/// The Merging section of the Clipboard pane (fast append). The options below
/// the main switch only matter while it is on, so they are disabled otherwise.
struct MergingSubpane: View {
    @ObservedObject private var settings = ClipboardSettings.shared

    var body: some View {
        Section {
            Toggle(isOn: $settings.fastAppendEnabled) {
                Text("Fast append selected text")
                Text("Hold ⌘ and double tap C to append the currently selected text to the "
                     + "previously copied text in the clipboard history.")
            }

            Group {
                Toggle(isOn: $settings.fastAppendBackToPasteboard) {
                    Text("Place merged text back into macOS clipboard")
                    Text("Lets you paste the merged text with ⌘V without opening "
                         + "\(Branding.name)'s clipboard history.")
                }

                Picker("Separate appended text with", selection: $settings.appendSeparator) {
                    ForEach(AppendSeparator.allCases) { sep in
                        Text(sep.label).tag(sep)
                    }
                }
                .pickerStyle(.menu)

                Toggle(isOn: $settings.playAppendSound) {
                    Text("Play a sound when appending")
                    Text("Plays the system “Purr” sound when an item is successfully appended.")
                }
            }
            .disabled(!settings.fastAppendEnabled)
        } header: {
            Text("Merging")
        }
    }
}
