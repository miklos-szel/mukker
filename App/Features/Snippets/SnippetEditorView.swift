import SwiftUI

struct SnippetEditorView: View {
    let snippet: Snippet
    var onSave: (Snippet) -> Void

    @State private var name: String = ""
    @State private var keyword: String = ""
    @State private var content: String = ""
    /// The snippet the current draft was loaded from — autosave targets this,
    /// not `snippet`, which has already changed by the time `onChange` fires.
    @State private var loadedSnippet: Snippet?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                TextField("Keyword (optional)", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .font(.system(.body, design: .monospaced))
            }
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .border(Color.secondary.opacity(0.2))
            HStack {
                Spacer()
                Button("Save") { saveDraftIfNeeded() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
            }
        }
        .padding()
        .onAppear { loadFromSnippet() }
        // Autosave pending edits when the selection moves to another snippet
        // (deferred: onSave mutates view-model state) and when the editor leaves
        // the screen (collection switch, window close).
        .onChange(of: snippet.id) { _, _ in
            let draft = pendingDraft()
            if let draft {
                DispatchQueue.main.async { onSave(draft) }
            }
            loadFromSnippet()
        }
        .onDisappear {
            if let draft = pendingDraft() { onSave(draft) }
        }
    }

    /// True when the draft differs from what's persisted — i.e. there's something to save.
    private var hasChanges: Bool {
        pendingDraft() != nil
    }

    /// The draft as a saveable snippet, or nil when nothing changed.
    private func pendingDraft() -> Snippet? {
        guard let original = loadedSnippet else { return nil }
        let kw = keyword.isEmpty ? nil : keyword
        guard name != original.name || kw != original.keyword || content != original.content else {
            return nil
        }
        var copy = original
        copy.name = name
        copy.keyword = kw
        copy.content = content
        return copy
    }

    private func saveDraftIfNeeded() {
        guard let draft = pendingDraft() else { return }
        loadedSnippet = draft
        onSave(draft)
    }

    private func loadFromSnippet() {
        loadedSnippet = snippet
        name = snippet.name
        keyword = snippet.keyword ?? ""
        content = snippet.content
    }
}
