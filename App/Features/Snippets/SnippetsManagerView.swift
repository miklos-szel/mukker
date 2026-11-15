import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// What an import wrote, for the confirmation shown afterwards.
struct SnippetImportSummary: Equatable {
    let collectionNames: [String]
    let snippetCount: Int

    var message: String {
        let snippets = "\(snippetCount) snippet\(snippetCount == 1 ? "" : "s")"
        let names = collectionNames.map { "“\($0)”" }
        switch names.count {
        case 0: return "Imported \(snippets)."
        case 1: return "Imported \(snippets) into \(names[0])."
        default: return "Imported \(snippets) into \(names.count) collections: "
                + names.joined(separator: ", ") + "."
        }
    }
}

/// A non-error confirmation shown after an import or export.
struct SnippetsManagerNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    /// When set, the notice offers "Show in Finder" for this file.
    var revealURL: URL?
}

@MainActor
final class SnippetsManagerViewModel: ObservableObject {
    @Published var collections: [SnippetCollection] = []
    @Published var snippets: [Snippet] = []
    @Published var selectedCollectionId: Int64? {
        didSet { reloadSnippets() }
    }
    @Published var selectedSnippetId: Int64?
    @Published var errorMessage: String?
    @Published var notice: SnippetsManagerNotice?
    /// The collection whose name is being edited in place, if any.
    @Published var renamingCollectionId: Int64?

    private let repo: SnippetRepository
    private let snippetCache: SnippetCache
    private var cancellables = Set<AnyCancellable>()

    /// `snippetCache` defaults to the shared cache (nil, because a main-actor
    /// default argument can't be written in a nonisolated position).
    init(repository: SnippetRepository = SnippetRepository(),
         snippetCache: SnippetCache? = nil) {
        let snippetCache = snippetCache ?? .shared
        self.repo = repository
        self.snippetCache = snippetCache
        // Stay in sync with writes from elsewhere (e.g. the popup's "add to
        // snippets" star), which all funnel through SnippetCache.loadAll().
        snippetCache.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        do {
            collections = try repo.allCollections()
            if selectedCollectionId == nil {
                selectedCollectionId = collections.first?.id
            }
            reloadSnippets()
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }
    }

    func reloadSnippets() {
        guard let id = selectedCollectionId else {
            snippets = []
            return
        }
        do {
            snippets = try repo.snippets(in: id)
            if !snippets.contains(where: { $0.id == selectedSnippetId }) {
                selectedSnippetId = snippets.first?.id
            }
        } catch {
            errorMessage = "Failed to load snippets: \(error.localizedDescription)"
        }
    }

    /// Creates "Untitled" and starts renaming it straight away.
    func createCollection() {
        do {
            let c = try repo.createCollection(name: "Untitled")
            snippetCache.loadAll()
            reload()
            selectedCollectionId = c.id
            renamingCollectionId = c.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelectedCollection() {
        guard let id = selectedCollectionId else { return }
        do {
            try repo.deleteCollection(id: id)
            selectedCollectionId = nil
            snippetCache.loadAll()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Renames `collection` to `newName`, trimmed. An empty or whitespace-only
    /// name keeps the previous one. Returns whether the name was saved.
    @discardableResult
    func renameCollection(_ collection: SnippetCollection, to newName: String) -> Bool {
        renamingCollectionId = nil
        guard let id = collection.id, let name = SnippetNaming.validated(newName) else { return false }
        guard name != collection.name else { return true }
        do {
            try repo.renameCollection(id: id, name: name)
            snippetCache.loadAll()
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func createSnippet() {
        guard let cid = selectedCollectionId else { return }
        do {
            let s = try repo.createSnippet(collectionId: cid, name: "New Snippet", keyword: nil, content: "")
            snippetCache.loadAll()
            reloadSnippets()
            selectedSnippetId = s.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSnippet(_ snippet: Snippet) {
        do {
            try repo.updateSnippet(snippet)
            snippetCache.loadAll()
            reloadSnippets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelectedSnippet() {
        guard let id = selectedSnippetId else { return }
        do {
            try repo.deleteSnippet(id: id)
            snippetCache.loadAll()
            reloadSnippets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var selectedSnippet: Snippet? {
        snippets.first(where: { $0.id == selectedSnippetId })
    }

    // MARK: Import / Export

    /// Imports a `.alfredsnippets` bundle, selects its collection and confirms
    /// what was imported. Returns the summary, or nil on failure.
    @discardableResult
    func importSnippetBundle(url: URL) -> SnippetImportSummary? {
        do {
            let parsed = try SnippetBundleImporter().parse(url: url)
            let snippets = parsed.snippets.map {
                (name: $0.name, keyword: $0.keyword, content: $0.content, uid: $0.uid)
            }
            let c = try repo.importCollection(
                name: parsed.name,
                keywordPrefix: parsed.keywordPrefix,
                keywordSuffix: parsed.keywordSuffix,
                snippets: snippets
            )
            snippetCache.loadAll()
            reload()
            selectedCollectionId = c.id
            let summary = SnippetImportSummary(collectionNames: [c.name], snippetCount: snippets.count)
            notice = SnippetsManagerNotice(title: "Import Complete", message: summary.message)
            return summary
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Imports one of our own export files, selects the first collection it
    /// wrote and confirms what was imported.
    @discardableResult
    func importFromMukker(url: URL) -> SnippetImportSummary? {
        do {
            let result = try MukkerImporter(repository: repo).importFileWithSummary(at: url)
            snippetCache.loadAll()
            reload()
            if let first = result.collections.first?.id { selectedCollectionId = first }
            let summary = SnippetImportSummary(collectionNames: result.collections.map(\.name),
                                               snippetCount: result.snippetCount)
            notice = SnippetsManagerNotice(title: "Import Complete", message: summary.message)
            return summary
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
            return nil
        }
    }

    func exportAll(to url: URL) {
        export(collectionIds: nil, to: url)
    }

    func exportSelected(to url: URL) {
        guard let id = selectedCollectionId else { return }
        export(collectionIds: [id], to: url)
    }

    private func export(collectionIds: [Int64]?, to url: URL) {
        do {
            try MukkerExporter(repository: repo).export(collectionIds: collectionIds, to: url)
            notice = SnippetsManagerNotice(title: "Export Complete",
                                           message: "Saved “\(url.lastPathComponent)”.",
                                           revealURL: url)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}

struct SnippetsManagerView: View {
    @StateObject private var vm = SnippetsManagerViewModel()
    @State private var showDeleteCollectionConfirm = false
    @State private var showDeleteSnippetConfirm = false

    var body: some View {
        Group {
            if vm.collections.isEmpty {
                noCollectionsPlaceholder
            } else {
                NavigationSplitView {
                    collectionsSidebar
                } content: {
                    snippetsList
                } detail: {
                    editor
                }
            }
        }
        .frame(minWidth: 880, minHeight: 520)
        .navigationTitle("Snippets")
        .toolbar { toolbar }
        .onAppear { vm.reload() }
        .alert("Error",
               isPresented: Binding(
                get: { vm.errorMessage != nil },
                set: { if !$0 { vm.errorMessage = nil } }
               ),
               actions: { Button("OK") { vm.errorMessage = nil } },
               message: { Text(vm.errorMessage ?? "") })
        .alert(vm.notice?.title ?? "",
               isPresented: Binding(
                get: { vm.notice != nil },
                set: { if !$0 { vm.notice = nil } }
               ),
               presenting: vm.notice,
               actions: { notice in
                   if let url = notice.revealURL {
                       Button("Show in Finder") {
                           NSWorkspace.shared.activateFileViewerSelecting([url])
                       }
                   }
                   Button("OK", role: .cancel) {}
               },
               message: { notice in Text(notice.message) })
    }

    /// Shown instead of three empty columns until there is a collection.
    private var noCollectionsPlaceholder: some View {
        ContentUnavailableView {
            Label("No Collections", systemImage: "folder")
        } description: {
            Text("Create a collection for your snippets, or import an existing snippet file.")
        } actions: {
            HStack {
                Button("New Collection", action: vm.createCollection)
                    .buttonStyle(.borderedProminent)
                Button("Import…", action: importAnyPanel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var collectionsSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $vm.selectedCollectionId) {
                ForEach(vm.collections) { collection in
                    CollectionRow(
                        collection: collection,
                        isEditing: vm.renamingCollectionId == collection.id && collection.id != nil,
                        onBeginRename: { vm.renamingCollectionId = collection.id },
                        onCommit: { newName in vm.renameCollection(collection, to: newName) },
                        onCancel: { vm.renamingCollectionId = nil })
                    .tag(collection.id ?? -1)
                    .contextMenu {
                        Button("Rename") {
                            vm.selectedCollectionId = collection.id
                            vm.renamingCollectionId = collection.id
                        }
                        Button("Delete…") {
                            vm.selectedCollectionId = collection.id
                            showDeleteCollectionConfirm = true
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button("New Collection", systemImage: "plus", action: vm.createCollection)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("New collection")
                Button("Delete Collection", systemImage: "minus") {
                    showDeleteCollectionConfirm = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete the selected collection")
                .disabled(vm.selectedCollectionId == nil)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 200)
        .confirmationDialog(deleteCollectionTitle,
                            isPresented: $showDeleteCollectionConfirm) {
            Button("Delete Collection", role: .destructive,
                   action: vm.deleteSelectedCollection)
        } message: {
            Text(vm.snippets.isEmpty
                 ? "This collection is empty."
                 : "This also deletes its \(vm.snippets.count) snippet\(vm.snippets.count == 1 ? "" : "s").")
        }
    }

    private var deleteCollectionTitle: String {
        let name = vm.collections.first(where: { $0.id == vm.selectedCollectionId })?.name ?? "collection"
        return "Delete “\(name)”?"
    }

    private var snippetsList: some View {
        VStack(spacing: 0) {
            if vm.snippets.isEmpty && vm.selectedCollectionId != nil {
                ContentUnavailableView {
                    Label("No Snippets", systemImage: "text.badge.plus")
                } description: {
                    Text("This collection is empty.")
                } actions: {
                    Button("New Snippet", action: vm.createSnippet)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $vm.selectedSnippetId) {
                    ForEach(vm.snippets) { snip in
                        VStack(alignment: .leading) {
                            Text(snip.name).font(.headline)
                            if let kw = snip.keyword, !kw.isEmpty {
                                Text(kw).font(.caption).foregroundStyle(.tint)
                            }
                            Text(snip.content.prefix(80))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .tag(snip.id ?? -1)
                        .contextMenu {
                            Button("Delete…") {
                                vm.selectedSnippetId = snip.id
                                showDeleteSnippetConfirm = true
                            }
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button("New Snippet", systemImage: "plus", action: vm.createSnippet)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("New snippet")
                    .disabled(vm.selectedCollectionId == nil)
                Button("Delete Snippet", systemImage: "minus") {
                    showDeleteSnippetConfirm = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete the selected snippet")
                .disabled(vm.selectedSnippetId == nil)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 240)
        .confirmationDialog("Delete “\(vm.selectedSnippet?.name ?? "snippet")”?",
                            isPresented: $showDeleteSnippetConfirm) {
            Button("Delete Snippet", role: .destructive,
                   action: vm.deleteSelectedSnippet)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let snippet = vm.selectedSnippet {
            SnippetEditorView(snippet: snippet) { updated in
                vm.updateSnippet(updated)
            }
        } else {
            VStack {
                Spacer()
                Text("Select a snippet").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                importPanel(asBundle: true)
            } label: {
                Label("Import Snippets…", systemImage: "square.and.arrow.down")
            }
            .help("Import a .alfredsnippets bundle")
            Button {
                importPanel(asBundle: false)
            } label: {
                Label("Import \(Branding.name) File", systemImage: "square.and.arrow.down.on.square")
            }
            .help("Import a \(Branding.name) snippet file")
            Button {
                exportPanel(allCollections: false)
            } label: {
                Label("Export Selected", systemImage: "square.and.arrow.up")
            }
            .help("Export the selected collection")
            .disabled(vm.selectedCollectionId == nil)
            Button {
                exportPanel(allCollections: true)
            } label: {
                Label("Export All", systemImage: "square.and.arrow.up.on.square")
            }
            .help("Export every collection")
            .disabled(vm.collections.isEmpty)
        }
    }

    private static let bundleType = UTType(filenameExtension: "alfredsnippets") ?? .data
    private static let nativeTypes: [UTType] = [.json, UTType(filenameExtension: "mukker") ?? .json]

    private func importPanel(asBundle: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = asBundle ? [Self.bundleType] : Self.nativeTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if asBundle {
            vm.importSnippetBundle(url: url)
        } else {
            vm.importFromMukker(url: url)
        }
    }

    /// One panel for either import format, dispatched on the file's extension
    /// (the empty state has room for a single "Import…" button).
    private func importAnyPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [Self.bundleType] + Self.nativeTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased() == "alfredsnippets" {
            vm.importSnippetBundle(url: url)
        } else {
            vm.importFromMukker(url: url)
        }
    }

    private func exportPanel(allCollections: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = allCollections
            ? "\(Branding.name.lowercased())-snippets.json"
            : "collection.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if allCollections {
            vm.exportAll(to: url)
        } else {
            vm.exportSelected(to: url)
        }
    }
}

/// A collection in the sidebar. Double-click (or "Rename" in the context menu,
/// or creating a new collection) edits the name in place: Return saves it, Esc
/// restores the old one, and clicking away saves it.
struct CollectionRow: View {
    let collection: SnippetCollection
    let isEditing: Bool
    var onBeginRename: () -> Void
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    @State private var draftName: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack {
            Image(systemName: "folder")
            if isEditing {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { onCommit(draftName) }
                    .onExitCommand { onCancel() }
                    .onAppear {
                        draftName = collection.name
                        // Focus after the field is in the window; focusing a
                        // field selects its whole text, so typing replaces it.
                        DispatchQueue.main.async { fieldFocused = true }
                    }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused, isEditing { onCommit(draftName) }
                    }
            } else {
                Text(collection.name)
                    .onTapGesture(count: 2, perform: onBeginRename)
            }
            Spacer()
        }
    }
}
