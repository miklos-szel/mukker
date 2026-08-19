import Foundation
import GRDB

final class ClipboardRepository {
    private let dbQueue: DatabaseQueue

    init(database: AppDatabase = .shared) {
        self.dbQueue = database.dbQueue
    }

    func recent(limit: Int = 200) throws -> [ClipItem] {
        try dbQueue.read { db in
            try ClipItem
                .order(sql: "pinned DESC, COALESCE(lastUsedAt, createdAt) DESC")
                .limit(limit)
                .fetchAll(db)
        }
    }

    func fetchOne(id: Int64) throws -> ClipItem? {
        try dbQueue.read { db in
            try ClipItem.fetchOne(db, key: id)
        }
    }

    func fetchOne(contentHash: String) throws -> ClipItem? {
        try dbQueue.read { db in
            try ClipItem
                .filter(ClipItem.Columns.contentHash == contentHash)
                .fetchOne(db)
        }
    }

    func bumpLastUsed(id: Int64, at date: Date = Date()) throws {
        try dbQueue.write { db in
            guard var item = try ClipItem.fetchOne(db, key: id) else { return }
            item.lastUsedAt = date
            try item.update(db)
        }
    }

    func updateTextContent(id: Int64, newContent: String, newHash: String) throws {
        // The stored RTF (if any) matched the old plain text; after a content
        // rewrite it would paste stale formatting, so drop it.
        let oldRTFPath: String? = try dbQueue.write { db in
            guard var item = try ClipItem.fetchOne(db, key: id) else { return nil }
            let oldPath = item.richTextPath
            item.textContent = newContent
            item.contentHash = newHash
            item.previewText = String(newContent.prefix(200))
            item.lastUsedAt = Date()
            item.richTextPath = nil
            try item.update(db)
            return oldPath
        }
        if let path = oldRTFPath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Delete unpinned rows of `kind` whose effective timestamp predates `cutoff`.
    /// Returns the deleted items so the caller can remove on-disk images and/or
    /// archive their text. (Dates are filtered in Swift on decoded values — GRDB
    /// stores `Date` as text, so a numeric SQL comparison would not work reliably.)
    @discardableResult
    func purgeOlderThan(kind: ClipKind, cutoff: Date) throws -> [ClipItem] {
        let removed: [ClipItem] = try dbQueue.write { db in
            let candidates = try ClipItem
                .filter(ClipItem.Columns.kind == kind.rawValue)
                .filter(ClipItem.Columns.pinned == false)
                .fetchAll(db)
                .filter { $0.effectiveTimestamp < cutoff }
            let ids = candidates.compactMap { $0.id }
            try ClipItem.deleteAll(db, keys: ids)
            return candidates
        }
        removeSidecarFiles(of: removed)
        return removed
    }

    @discardableResult
    func insertIfNew(_ item: ClipItem) throws -> ClipItem? {
        try dbQueue.write { db in
            let existing = try ClipItem
                .filter(ClipItem.Columns.contentHash == item.contentHash)
                .fetchOne(db)
            if existing != nil { return nil }
            var copy = item
            try copy.insert(db)
            return copy
        }
    }

    func delete(id: Int64) throws {
        let deleted: ClipItem? = try dbQueue.write { db in
            let item = try ClipItem.fetchOne(db, key: id)
            try ClipItem.deleteOne(db, key: id)
            return item
        }
        if let deleted { removeSidecarFiles(of: [deleted]) }
    }

    /// Returns the deleted items (so callers can archive their text).
    @discardableResult
    func clearAll(keepPinned: Bool = true) throws -> [ClipItem] {
        let victims: [ClipItem] = try dbQueue.write { db in
            let request = keepPinned
                ? ClipItem.filter(ClipItem.Columns.pinned == false)
                : ClipItem.all()
            let items = try request.fetchAll(db)
            try ClipItem.deleteAll(db, keys: items.compactMap { $0.id })
            return items
        }
        removeSidecarFiles(of: victims)
        return victims
    }

    func togglePinned(id: Int64) throws {
        try dbQueue.write { db in
            guard var item = try ClipItem.fetchOne(db, key: id) else { return }
            item.pinned.toggle()
            try item.update(db)
        }
    }

    /// Limit history size by deleting the least-recently-used unpinned items above
    /// `maxItems` (same effective order as `recent`, so the visible top of history
    /// is never trimmed). Returns the deleted items so callers can archive them.
    @discardableResult
    func trim(to maxItems: Int) throws -> [ClipItem] {
        let victims: [ClipItem] = try dbQueue.write { db in
            let count = try ClipItem.filter(ClipItem.Columns.pinned == false).fetchCount(db)
            let excess = count - maxItems
            guard excess > 0 else { return [] }
            let victims = try ClipItem
                .filter(ClipItem.Columns.pinned == false)
                .order(sql: "COALESCE(lastUsedAt, createdAt) ASC")
                .limit(excess)
                .fetchAll(db)
            try ClipItem.deleteAll(db, keys: victims.compactMap { $0.id })
            return victims
        }
        removeSidecarFiles(of: victims)
        return victims
    }

    /// Best-effort removal of the on-disk files (image PNG / RTF) owned by
    /// deleted rows. Content-hash dedupe guarantees one row per file, so a
    /// deleted row's sidecars are never shared with a surviving row.
    private func removeSidecarFiles(of items: [ClipItem]) {
        let fm = FileManager.default
        for path in items.flatMap(\.sidecarPaths) {
            try? fm.removeItem(atPath: path)
        }
    }
}
