import SwiftUI

struct HistorySubpane: View {
    @ObservedObject private var settings = ClipboardSettings.shared
    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                RetentionBox(title: "Keep Plain Text",
                             isOn: $settings.keepText,
                             period: $settings.textRetention)
                RetentionBox(title: "Keep Images",
                             isOn: $settings.keepImages,
                             period: $settings.imageRetention)
                RetentionBox(title: "Keep File Lists",
                             isOn: $settings.keepFiles,
                             period: $settings.fileRetention)
            }
            Toggle("Move items to top of clipboard history when used",
                   isOn: $settings.moveToTopOnUse)
            Text("When disabled, the clipboard viewer can still show your snippets.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Highlight search matches in preview",
                   isOn: $settings.highlightSearchMatches)
            Text("Highlights the text you're searching for inside the history preview.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper(value: $settings.maxHistoryItems, in: 50...10000, step: 50) {
                Text("Keep up to \(settings.maxHistoryItems) items")
            }
            .fixedSize()
            Text("Older unpinned items beyond this limit are removed from history.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Clear History…", role: .destructive) {
                showClearConfirm = true
            }
            .confirmationDialog("Clear clipboard history?",
                                isPresented: $showClearConfirm) {
                Button("Clear Unpinned Items", role: .destructive, action: clearHistory)
            } message: {
                Text("Removes all unpinned items from the clipboard history. Pinned items are kept.")
            }
        }
    }

    private func clearHistory() {
        do {
            let removed = try ClipboardRepository().clearAll(keepPinned: true)
            // Honor the forever-history promise even for an explicit clear.
            ForeverHistoryArchive.archive(removed)
            ClipboardCache.shared.loadAll()
        } catch {
            Log.clipboard.error("Clear history failed: \(error.localizedDescription)")
        }
    }
}
