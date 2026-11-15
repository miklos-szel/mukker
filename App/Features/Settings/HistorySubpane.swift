import SwiftUI

/// The History sections of the Clipboard pane: what is kept and for how long,
/// the item limit, ordering and search highlighting, and clearing.
struct HistorySubpane: View {
    @ObservedObject private var settings = ClipboardSettings.shared
    @State private var showClearConfirm = false
    @State private var clearError: String?

    static let maxItemsRange = 50...10_000

    var body: some View {
        Section {
            RetentionRow(title: "Keep plain text",
                         isOn: $settings.keepText,
                         period: $settings.textRetention)
            RetentionRow(title: "Keep images",
                         isOn: $settings.keepImages,
                         period: $settings.imageRetention)
            RetentionRow(title: "Keep file lists",
                         isOn: $settings.keepFiles,
                         period: $settings.fileRetention)
            LabeledContent("Keep up to") {
                HStack(spacing: 6) {
                    TextField("", value: maxItems, format: .number)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Maximum history items")
                    Text("items").foregroundStyle(.secondary)
                    Stepper("", value: maxItems, in: Self.maxItemsRange, step: 50)
                        .labelsHidden()
                        .accessibilityLabel("Maximum history items")
                }
            }
        } header: {
            Text("History")
        } footer: {
            SettingsFootnote("Each kind is kept for the period shown; with all three off, "
                             + "nothing new is recorded and the popup still shows your snippets. "
                             + "Older unpinned items beyond the item limit are removed.")
        }

        Section {
            Toggle(isOn: $settings.moveToTopOnUse) {
                Text("Move items to top of clipboard history when used")
                Text("Pasting an item from the popup, or copying the same thing again, "
                     + "moves it to the top instead of leaving it where it was.")
            }
            Toggle(isOn: $settings.highlightSearchMatches) {
                Text("Highlight search matches in preview")
                Text("Highlights the text you're searching for inside the history preview.")
            }
            Button("Clear History…", role: .destructive) {
                showClearConfirm = true
            }
            .confirmationDialog("Clear clipboard history?",
                                isPresented: $showClearConfirm) {
                Button("Clear Unpinned Items", role: .destructive, action: clearHistory)
            } message: {
                Text("Removes all unpinned items from the clipboard history. Pinned items are kept.")
            }
            .alert("Couldn't clear the history",
                   isPresented: Binding(get: { clearError != nil },
                                        set: { if !$0 { clearError = nil } }),
                   actions: { Button("OK") { clearError = nil } },
                   message: { Text(clearError ?? "") })
        }
    }

    /// The item limit, clamped to the stepper's range whichever control set it.
    private var maxItems: Binding<Int> {
        Binding(
            get: { settings.maxHistoryItems },
            set: { newValue in
                let clamped = min(max(newValue, Self.maxItemsRange.lowerBound),
                                  Self.maxItemsRange.upperBound)
                if clamped != settings.maxHistoryItems { settings.maxHistoryItems = clamped }
            })
    }

    private func clearHistory() {
        do {
            let removed = try ClipboardRepository().clearAll(keepPinned: true)
            // Honor the forever-history promise even for an explicit clear.
            ForeverHistoryArchive.archive(removed)
            ClipboardCache.shared.loadAll()
        } catch {
            Log.clipboard.error("Clear history failed: \(error.localizedDescription)")
            clearError = error.localizedDescription
        }
    }
}
