import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SnippetsManagerViewModel: ObservableObject {
    @Published var collections: [SnippetCollection] = []
    @Published var snippets: [Snippet] = []
    @Published var selectedCollectionId: Int64? {
        didSet { reloadSnippets() }
    }
    @Published var selectedSnippetId: Int64?
    @Published var errorMessage: String?

    private let repo = SnippetRepository()
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Stay in sync with writes from elsewhere (e.g. the popup's "add to
        // snippets" star), which all funnel through SnippetCache.loadAll().
        SnippetCache.shared.objectWillChange
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

    func createCollection() {
        do {
            let c = try repo.createCollection(name: "Untitled")
            SnippetCache.shared.loadAll()
            reload()
            selectedCollectionId = c.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelectedCollection() {
        guard let id = selectedCollectionId else { return }
        do {
            try repo.deleteCollection(id: id)
            selectedCollectionId = nil
            SnippetCache.shared.loadAll()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameCollection(_ collection: SnippetCollection, to newName: String) {
        guard let id = collection.id else { return }
        do {
            try repo.renameCollection(id: id, name: newName)
            SnippetCache.shared.loadAll()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createSnippet() {
        guard let cid = selectedCollectionId else { return }
        do {
            let s = try repo.createSnippet(collectionId: cid, name: "New Snippet", keyword: nil, content: "")
            SnippetCache.shared.loadAll()
            reloadSnippets()
            selectedSnippetId = s.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateSnippet(_ snippet: Snippet) {
        do {
            try repo.updateSnippet(snippet)
            SnippetCache.shared.loadAll()
            reloadSnippets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelectedSnippet() {
        guard let id = selectedSnippetId else { return }
        do {
            try repo.deleteSnippet(id: id)
            SnippetCache.shared.loadAll()
            reloadSnippets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var selectedSnippet: Snippet? {
        snippets.first(where: { $0.id == selectedSnippetId })
    }

    // MARK: Import / Export

    func importSnippetBundle(url: URL) {
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
            SnippetCache.shared.loadAll()
            reload()
            selectedCollectionId = c.id
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func importFromMukker(url: URL) {
        do {
            _ = try MukkerImporter().importFile(at: url)
            SnippetCache.shared.loadAll()
            reload()
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func exportAll(to url: URL) {
        do {
            try MukkerExporter().export(collectionIds: nil, to: url)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func exportSelected(to url: URL) {
        guard let id = selectedCollectionId else { return }
        do {
            try MukkerExporter().export(collectionIds: [id], to: url)
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
        NavigationSplitView {
            collectionsSidebar
        } content: {
            snippetsList
        } detail: {
            editor
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
    }

    private var collectionsSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $vm.selectedCollectionId) {
                ForEach(vm.collections) { collection in
                    CollectionRow(collection: collection) { newName in
                        vm.renameCollection(collection, to: newName)
                    }
                    .tag(collection.id ?? -1)
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button("New Collection", systemImage: "plus", action: vm.createCollection)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                Button("Delete Collection", systemImage: "minus") {
                    showDeleteCollectionConfirm = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
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
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button("New Snippet", systemImage: "plus", action: vm.createSnippet)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(vm.selectedCollectionId == nil)
                Button("Delete Snippet", systemImage: "minus") {
                    showDeleteSnippetConfirm = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
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
            Button {
                importPanel(asBundle: false)
            } label: {
                Label("Import \(Branding.name) File", systemImage: "square.and.arrow.down.on.square")
            }
            Button {
                exportPanel(allCollections: false)
            } label: {
                Label("Export Selected", systemImage: "square.and.arrow.up")
            }
            .disabled(vm.selectedCollectionId == nil)
            Button {
                exportPanel(allCollections: true)
            } label: {
                Label("Export All", systemImage: "square.and.arrow.up.on.square")
            }
        }
    }

    private func importPanel(asBundle: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if asBundle {
            panel.allowedContentTypes = [.init(filenameExtension: "alfredsnippets") ?? .data]
        } else {
            panel.allowedContentTypes = [.json, .init(filenameExtension: "mukker") ?? .json]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if asBundle {
            vm.importSnippetBundle(url: url)
        } else {
            vm.importFromMukker(url: url)
        }
    }

    private func exportPanel(allCollections: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = allCollections ? "mukker-snippets.json" : "collection.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if allCollections {
            vm.exportAll(to: url)
        } else {
            vm.exportSelected(to: url)
        }
    }
}

struct CollectionRow: View {
    let collection: SnippetCollection
    var onRename: (String) -> Void

    @State private var isEditing = false
    @State private var draftName: String = ""

    var body: some View {
        HStack {
            Image(systemName: "folder")
            if isEditing {
                TextField("Name", text: $draftName, onCommit: {
                    onRename(draftName)
                    isEditing = false
                })
                .textFieldStyle(.roundedBorder)
            } else {
                Text(collection.name)
                    .onTapGesture(count: 2) {
                        draftName = collection.name
                        isEditing = true
                    }
            }
            Spacer()
        }
    }
}
