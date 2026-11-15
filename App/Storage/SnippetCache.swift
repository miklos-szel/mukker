import Combine
import Foundation

/// In-memory cache of all collections and snippets.
/// Snippets are small; we keep the whole set and filter in-memory for instant popup rendering.
/// Mutations go through `SnippetRepository`; the code that writes (the Snippets
/// Manager, the popup's "add to snippets" star) calls `loadAll()` afterwards to
/// keep this in sync — the repository itself never touches the cache.
@MainActor
final class SnippetCache: ObservableObject {
    static let shared = SnippetCache()

    /// Everything `loadAll` produces, published as one value so a reload
    /// notifies observers once instead of once per field.
    private struct Contents {
        var collections: [SnippetCollection] = []
        var snippetsByCollection: [Int64: [Snippet]] = [:]
        var allSnippetsSorted: [Snippet] = []
    }

    @Published private var contents = Contents()

    var collections: [SnippetCollection] { contents.collections }
    var snippetsByCollection: [Int64: [Snippet]] { contents.snippetsByCollection }
    var allSnippetsSorted: [Snippet] { contents.allSnippetsSorted }

    private let repo: SnippetRepository

    init(repository: SnippetRepository = SnippetRepository()) {
        self.repo = repository
    }

    func loadAll() {
        do {
            let cols = try repo.allCollections()
            // One query for every snippet, already in per-collection order
            // (name, then id); grouping keeps that order within each group.
            let grouped = Dictionary(grouping: try repo.allSnippetsOrderedByName(), by: \.collectionId)
            var map: [Int64: [Snippet]] = [:]
            var flat: [Snippet] = []
            for c in cols {
                guard let cid = c.id else { continue }
                let snips = grouped[cid] ?? []
                map[cid] = snips
                flat.append(contentsOf: snips)
            }
            flat.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            var keys: [Int64: SearchKey] = [:]
            for snip in flat {
                if let id = snip.id { keys[id] = SearchKey(snip) }
            }
            searchKeys = keys
            contents = Contents(collections: cols, snippetsByCollection: map, allSnippetsSorted: flat)
        } catch {
            Log.snippets.error("SnippetCache loadAll failed: \(error.localizedDescription)")
        }
    }

    func snippets(in collectionId: Int64?) -> [Snippet] {
        if let cid = collectionId {
            return snippetsByCollection[cid] ?? []
        }
        return allSnippetsSorted
    }

    /// Case-insensitive substring match on snippet name or keyword (never content).
    func filterByName(_ query: String, in collectionId: Int64?) -> [Snippet] {
        let base = snippets(in: collectionId)
        guard !query.isEmpty else { return base }
        let q = query.lowercased()
        return base.filter { snip in
            let key = snip.id.flatMap { searchKeys[$0] } ?? SearchKey(snip)
            if key.name.contains(q) { return true }
            if let kw = key.keyword, kw.contains(q) { return true }
            return false
        }
    }

    /// Lowercased name/keyword per snippet id, built in `loadAll` so a keystroke
    /// lowercases only the query. (`lowercased()` + `contains`, not a
    /// `.caseInsensitive` search, which folds "ß"/"ss" and ligatures differently.)
    private var searchKeys: [Int64: SearchKey] = [:]

    private struct SearchKey {
        let name: String
        let keyword: String?

        init(_ snippet: Snippet) {
            name = snippet.name.lowercased()
            keyword = snippet.keyword?.lowercased()
        }
    }
}
