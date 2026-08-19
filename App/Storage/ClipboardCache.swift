import Combine
import Foundation

/// In-memory cache of recent clipboard items, newest first.
/// For text items, the full `textContent` is kept only when under `textInlineThreshold` bytes
/// (default 3 KB). Larger text items keep `textContent == nil` in the cache; consumers fetch
/// the full content lazily from the DB when previewing.
/// Image items keep paths + metadata; the PNG stays on disk.
@MainActor
final class ClipboardCache: ObservableObject {
    static let shared = ClipboardCache()

    /// Threshold in bytes for inlining text content into the cache.
    let textInlineThreshold: Int = 3 * 1024

    /// Maximum number of items kept resident.
    let maxResident: Int = 500

    @Published private(set) var items: [ClipItem] = []

    private let repo: ClipboardRepository

    init(repository: ClipboardRepository = ClipboardRepository()) {
        self.repo = repository
    }

    func loadAll() {
        do {
            let recent = try repo.recent(limit: maxResident)
            self.items = recent.map { stripLargeText($0) }
        } catch {
            Log.clipboard.error("ClipboardCache loadAll failed: \(error.localizedDescription)")
        }
    }

    /// Insert a newly captured item at the front. Pinned items stay above unpinned by sort.
    func insertNew(_ item: ClipItem) {
        items.insert(stripLargeText(item), at: 0)
        resort()
        trim()
    }

    func remove(id: Int64) {
        items.removeAll { $0.id == id }
    }

    func togglePinned(id: Int64) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned.toggle()
        resort()
    }

    func bumpLastUsed(id: Int64) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].lastUsedAt = Date()
        resort()
    }

    func update(_ item: ClipItem) {
        guard let id = item.id, let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx] = stripLargeText(item)
        resort()
    }

    /// Update the cached copy if resident, else insert it (e.g. a re-copied
    /// duplicate that had already fallen out of the resident window).
    func upsert(_ item: ClipItem) {
        if let id = item.id, items.contains(where: { $0.id == id }) {
            update(item)
        } else {
            insertNew(item)
        }
    }

    /// Filter newest-first by query against previewText, inlined textContent (when present), and sourceApp.
    func filter(_ query: String) -> [ClipItem] {
        guard !query.isEmpty else { return items }
        let q = query.lowercased()
        return items.filter { item in
            if let preview = item.previewText?.lowercased(), preview.contains(q) { return true }
            if let text = item.textContent?.lowercased(), text.contains(q) { return true }
            if let app = item.sourceApp?.lowercased(), app.contains(q) { return true }
            return false
        }
    }

    /// Returns the full text content for an item, fetching from DB if not cached inline.
    func fullText(for item: ClipItem) -> String? {
        if item.kind == .text {
            if let t = item.textContent { return t }
            guard let id = item.id else { return nil }
            do {
                if let full = try repo.fetchOne(id: id) {
                    return full.textContent
                }
            } catch {
                Log.clipboard.error("fullText fetch failed: \(error.localizedDescription)")
            }
        }
        return nil
    }

    // MARK: Private

    private func stripLargeText(_ item: ClipItem) -> ClipItem {
        guard item.kind == .text else { return item }
        guard let txt = item.textContent else { return item }
        if txt.utf8.count >= textInlineThreshold {
            var copy = item
            copy.textContent = nil
            return copy
        }
        return item
    }

    private func resort() {
        items.sort { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            // Use the effective timestamp so a used (bumped) item rises to the top.
            return a.effectiveTimestamp > b.effectiveTimestamp
        }
    }

    private func trim() {
        if items.count > maxResident {
            items.removeLast(items.count - maxResident)
        }
    }
}
