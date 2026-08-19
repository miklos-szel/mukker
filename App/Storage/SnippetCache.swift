import Combine
import Foundation

/// In-memory cache of all collections and snippets.
/// Snippets are small; we keep the whole set and filter in-memory for instant popup rendering.
/// Mutations happen in `SnippetRepository`; it calls `reload()` to keep this in sync.
@MainActor
final class SnippetCache: ObservableObject {
    static let shared = SnippetCache()

    @Published private(set) var collections: [SnippetCollection] = []
    @Published private(set) var snippetsByCollection: [Int64: [Snippet]] = [:]
    @Published private(set) var allSnippetsSorted: [Snippet] = []

    private let repo: SnippetRepository

    init(repository: SnippetRepository = SnippetRepository()) {
        self.repo = repository
    }

    func loadAll() {
        do {
            let cols = try repo.allCollections()
            var map: [Int64: [Snippet]] = [:]
            var flat: [Snippet] = []
            for c in cols {
                guard let cid = c.id else { continue }
                let snips = try repo.snippets(in: cid)
                map[cid] = snips
                flat.append(contentsOf: snips)
            }
            flat.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.collections = cols
            self.snippetsByCollection = map
            self.allSnippetsSorted = flat
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
            if snip.name.lowercased().contains(q) { return true }
            if let kw = snip.keyword?.lowercased(), kw.contains(q) { return true }
            return false
        }
    }
}
