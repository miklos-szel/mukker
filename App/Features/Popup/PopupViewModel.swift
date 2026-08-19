import AppKit
import Combine
import Foundation
import SwiftUI

/// A single row shown in the unified popup list.
enum PopupResult: Identifiable, Equatable {
    case collection(SnippetCollection)
    case snippet(Snippet)
    case clip(ClipItem)

    var id: String {
        switch self {
        case .collection(let c): return "c:\(c.id ?? -1)"
        case .snippet(let s):    return "s:\(s.id ?? -1)"
        case .clip(let k):       return "k:\(k.id ?? -1)"
        }
    }
}

@MainActor
final class PopupViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { visibleClipCount = clipPageSize; refreshResults() }
    }

    /// nil = top level (collections + history); set = drilled into a collection
    @Published var currentCollection: SnippetCollection? {
        didSet { visibleClipCount = clipPageSize; refreshResults() }
    }

    /// History is shown in pages: only `visibleClipCount` clip rows render at a
    /// time (lazy-loaded as the user scrolls/arrows down). Search still filters
    /// the full cache — `clipResults` is just a window over the matches.
    private let clipPageSize = 50
    private var visibleClipCount = 50
    /// Full set of clip matches for the current query (for paging + counts).
    private var allClipMatches: [PopupResult] = []

    @Published private(set) var results: [PopupResult] = []
    /// Pre-split sections so the list view doesn't re-filter `results` on every render.
    @Published private(set) var snippetResults: [PopupResult] = []
    @Published private(set) var clipResults: [PopupResult] = []
    @Published var selectedId: String?

    /// Invoked when an action requests the popup to close (set by the window controller).
    var onRequestClose: (() -> Void)?

    /// Header shown above the snippet/collection section.
    var snippetSectionHeader: String {
        currentCollection == nil && query.isEmpty ? "Collections" : "Snippets"
    }

    /// Bumped when the view should programmatically scroll the selection into view.
    @Published private(set) var scrollTick: Int = 0

    /// Bumped on every `reset()` (i.e. every popup open). The list view keys its
    /// `ScrollView` on this so it gets a fresh identity per open and starts at the
    /// top instantly — no animated scroll-up — with the first row selected.
    @Published private(set) var showGeneration: Int = 0

    private let snippetCache: SnippetCache
    private let clipboardCache: ClipboardCache

    private var cancellables: Set<AnyCancellable> = []

    init(snippetCache: SnippetCache = .shared,
         clipboardCache: ClipboardCache = .shared) {
        self.snippetCache = snippetCache
        self.clipboardCache = clipboardCache

        // Keep results in sync when the underlying caches change.
        snippetCache.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshResults() }
            }
            .store(in: &cancellables)
        clipboardCache.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshResults() }
            }
            .store(in: &cancellables)
    }

    /// Reset to a clean state for every popup show: top level, empty query,
    /// selection on the first row. Never restores where the user left off.
    func reset() {
        selectedId = nil            // clear before refresh so no stale row is preserved
        visibleClipCount = clipPageSize
        currentCollection = nil
        query = ""                  // didSet → refreshResults() selects results.first
        refreshResults()
        showGeneration &+= 1        // fresh ScrollView identity → starts at the top
    }

    /// Forces the selection back to the first row. Called right after the popup is
    /// shown so every reopen lands on the top row, even if a queued background cache
    /// refresh nudged the selection. No scroll bump: the list's fresh `showGeneration`
    /// identity already starts at the top, so we never animate a scroll-up.
    func selectFirstRow() {
        selectedId = results.first?.id
    }

    func refreshResults() {
        var rows: [PopupResult] = []

        // ── Snippets / collections section ─────────────────────────
        if query.isEmpty {
            if let col = currentCollection {
                // Inside a collection, empty query → list its snippets
                for snip in snippetCache.snippets(in: col.id) {
                    rows.append(.snippet(snip))
                }
            } else {
                // Top level, empty query → list all collections
                for col in snippetCache.collections {
                    rows.append(.collection(col))
                }
            }
        } else {
            // With query → match snippet names (scoped to collection if drilled in)
            let scope = currentCollection?.id
            for snip in snippetCache.filterByName(query, in: scope) {
                rows.append(.snippet(snip))
            }
        }

        let snippetRows = rows

        // ── Clipboard history section ──────────────────────────────
        // Filter runs over the whole cache so search hits every item; only the
        // first `visibleClipCount` matches are shown (the rest lazy-load).
        let clipMatches = clipboardCache.filter(query).map { PopupResult.clip($0) }
        allClipMatches = clipMatches
        let clipRows = Array(clipMatches.prefix(visibleClipCount))
        rows.append(contentsOf: clipRows)

        results = rows
        snippetResults = snippetRows
        clipResults = clipRows

        // Maintain a valid selection
        if let sel = selectedId, results.contains(where: { $0.id == sel }) {
            // keep
        } else {
            selectedId = results.first?.id
        }
        scrollTick &+= 1
    }

    // MARK: Navigation

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let ids = results.map(\.id)
        if let sel = selectedId, let idx = ids.firstIndex(of: sel) {
            let next = max(0, min(ids.count - 1, idx + delta))
            selectedId = ids[next]
            // Pull in the next page when arrowing onto the last clip row.
            if ids[next] == clipResults.last?.id { loadMoreClips() }
        } else {
            selectedId = ids.first
        }
        scrollTick &+= 1
    }

    /// True when more cached clip matches exist beyond the current window.
    var hasMoreClips: Bool { clipResults.count < allClipMatches.count }

    /// Grows the visible history window by one page.
    func loadMoreClips() {
        guard hasMoreClips else { return }
        visibleClipCount += clipPageSize
        refreshResults()
    }

    /// Called as a clip row scrolls into view; loads the next page when the last
    /// visible row appears. Deferred so we don't mutate state mid view-update.
    func onClipRowAppear(_ result: PopupResult) {
        guard result.id == clipResults.last?.id, hasMoreClips else { return }
        Task { @MainActor in self.loadMoreClips() }
    }

    var selectedResult: PopupResult? {
        guard let id = selectedId else { return nil }
        return results.first(where: { $0.id == id })
    }

    /// Drills into a collection (no paste).
    func enter(_ collection: SnippetCollection) {
        currentCollection = collection
        query = ""
    }

    /// Exits the current collection (back to top level). Returns true if drill-out happened.
    @discardableResult
    func exitCollection() -> Bool {
        guard currentCollection != nil else { return false }
        currentCollection = nil
        return true
    }

    // MARK: Add a clip to snippets

    private let snippetRepo = SnippetRepository()

    /// Adds a text clip's content as a snippet in an existing collection.
    func addClip(_ item: ClipItem, toCollectionId cid: Int64) {
        guard let text = fullText(of: item), !text.isEmpty else { return }
        do {
            try snippetRepo.createSnippet(collectionId: cid, name: snippetName(from: text),
                                          keyword: nil, content: text)
            snippetCache.loadAll()
        } catch {
            Log.snippets.error("Failed to add clip to collection: \(error.localizedDescription)")
        }
    }

    /// Creates a new collection and adds the text clip into it.
    func addClip(_ item: ClipItem, toNewCollection name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let text = fullText(of: item), !text.isEmpty else { return }
        do {
            let col = try snippetRepo.createCollection(name: trimmed)
            if let cid = col.id {
                try snippetRepo.createSnippet(collectionId: cid, name: snippetName(from: text),
                                              keyword: nil, content: text)
            }
            snippetCache.loadAll()
        } catch {
            Log.snippets.error("Failed to add clip to new collection: \(error.localizedDescription)")
        }
    }

    /// Full text for a clip, fetching from the DB when the cache stripped it.
    private func fullText(of item: ClipItem) -> String? {
        if let t = item.textContent { return t }
        return clipboardCache.fullText(for: item)
    }

    /// The item with its full text restored when the cache stripped it (text
    /// items over the inline threshold); other items pass through unchanged.
    private func resolvedForPaste(_ item: ClipItem) -> ClipItem {
        guard item.kind == .text, item.textContent == nil else { return item }
        var copy = item
        copy.textContent = clipboardCache.fullText(for: item) ?? ""
        return copy
    }

    /// Derives a snippet name from the first non-empty line, truncated.
    private func snippetName(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let name = firstLine.isEmpty ? "Snippet" : String(firstLine.prefix(50))
        return name
    }

    // MARK: Intent (called from the view; keeps logic out of the view body)

    /// Enter pressed in the search field, or a row was double-clicked.
    func submit() {
        if confirmSelection() { onRequestClose?() }
    }

    /// A specific row was activated (double-click).
    func activate(_ result: PopupResult) {
        selectedId = result.id
        if confirmSelection() { onRequestClose?() }
    }

    /// Esc pressed: always close the popup (drilling out stays available via the
    /// breadcrumb button or left-arrow at the caret start).
    func cancel() {
        onRequestClose?()
    }

    /// Backspace at the start of an empty field, or left-arrow at the caret start: drill out.
    func drillOutIfEmpty() {
        if query.isEmpty { _ = exitCollection() }
    }

    /// Right-arrow at the caret end: drill into the selected collection.
    func drillInIfCollection() {
        if case .collection = selectedResult { _ = confirmSelection() }
    }

    /// ⌘C: copy the selected snippet/clip to the clipboard WITHOUT pasting, then
    /// close the popup. Collections have nothing to copy, so they're ignored.
    func copySelection() {
        guard let result = selectedResult else { return }
        switch result {
        case .collection:
            return
        case .snippet(let snip):
            Paster.shared.pasteText(snip.content, autoPaste: false)
            onRequestClose?()
        case .clip(let item):
            Paster.shared.paste(resolvedForPaste(item), autoPaste: false)
            onRequestClose?()
        }
    }

    /// ⌘⇧V: paste the selected item as PLAIN text (strip formatting), then close.
    /// Honors `autoPasteEnabled` like Enter (copies-only when auto-paste is off).
    func pastePlainSelection() {
        guard let result = selectedResult else { return }
        let autoPaste = ClipboardSettings.shared.autoPasteEnabled
        switch result {
        case .collection:
            return
        case .snippet(let snip):
            Paster.shared.pasteText(snip.content, autoPaste: autoPaste)
            onRequestClose?()
        case .clip(let item):
            if item.kind == .text {
                let text = fullText(of: item) ?? item.previewText ?? ""
                Paster.shared.pasteText(text, autoPaste: autoPaste)
            } else {
                // Plain paste is meaningless for images/files — fall back to normal.
                Paster.shared.paste(item, autoPaste: autoPaste)
            }
            onRequestClose?()
        }
    }

    /// Acts on the current selection. Returns true if the popup should close after.
    /// Drill-in returns false (popup stays open).
    func confirmSelection() -> Bool {
        guard let result = selectedResult else { return false }
        let autoPaste = ClipboardSettings.shared.autoPasteEnabled
        switch result {
        case .collection(let col):
            enter(col)
            return false
        case .snippet(let snip):
            Paster.shared.pasteText(snip.content, autoPaste: autoPaste)
            return true
        case .clip(let item):
            Paster.shared.paste(resolvedForPaste(item), autoPaste: autoPaste)
            return true
        }
    }
}
