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

    /// Points a row at its RTF sidecar (or clears it with nil). Used when a re-copy
    /// brings formatting for a text row that was first stored plain, and to undo
    /// the reference when writing the file fails.
    func setRichTextPath(id: Int64, path: String?) throws {
        try dbQueue.write { db in
            guard var item = try ClipItem.fetchOne(db, key: id) else { return }
            item.richTextPath = path
            try item.update(db)
        }
    }

    /// Deletes the files in `directories` that no row references (image PNGs and
    /// RTFs left behind by older builds, which wrote them before the insert).
    /// Returns how many were removed. Blocking file I/O — call it off the main thread.
    ///
    /// Race-free against live captures because of two orderings:
    ///  - captures insert the row *before* writing its file, so every file that
    ///    exists when the directories are listed already has its row;
    ///  - the references are read and the orphans deleted inside one database
    ///    access, which `DatabaseQueue` serialises with every write — a capture
    ///    can't insert a row for a just-listed name between our read and the delete
    ///    (it waits, then rewrites its file after the delete).
    /// Files are matched by name (they are hash-named and unique per directory), so
    /// a row whose stored absolute path went stale still protects its file.
    @discardableResult
    func removeOrphanedSidecarFiles(in directories: [URL]) throws -> Int {
        let fm = FileManager.default
        var candidates: [URL] = []
        for dir in directories {
            let urls = (try? fm.contentsOfDirectory(at: dir,
                                                    includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles])) ?? []
            candidates += urls.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }
        guard !candidates.isEmpty else { return 0 }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, ClipItem
                .select(ClipItem.Columns.imagePath, ClipItem.Columns.richTextPath)
                .filter(ClipItem.Columns.imagePath != nil || ClipItem.Columns.richTextPath != nil))
            var referenced = Set<String>()
            for row in rows {
                for column in [ClipItem.Columns.imagePath, ClipItem.Columns.richTextPath] {
                    if let path: String = row[column.name] {
                        referenced.insert((path as NSString).lastPathComponent)
                    }
                }
            }
            var removed = 0
            for url in candidates where !referenced.contains(url.lastPathComponent) {
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
            return removed
        }
    }

    /// Delete unpinned rows of `kind` whose effective timestamp predates `cutoff`.
    /// Returns the deleted items so the caller can remove on-disk images and/or
    /// archive their text. (Dates are filtered in Swift on decoded values — GRDB
    /// stores `Date` as text, so a numeric SQL comparison would not work reliably.)
    ///
    /// Victims are picked from just `id`/`createdAt`/`lastUsedAt`; only they are
    /// then fetched in full, so a sweep that deletes nothing never loads any text.
    @discardableResult
    func purgeOlderThan(kind: ClipKind, cutoff: Date) throws -> [ClipItem] {
        let removed: [ClipItem] = try dbQueue.write { db in
            let rows = try Row.fetchAll(db, ClipItem
                .select(ClipItem.Columns.id, ClipItem.Columns.createdAt, ClipItem.Columns.lastUsedAt)
                .filter(ClipItem.Columns.kind == kind.rawValue)
                .filter(ClipItem.Columns.pinned == false))
            let ids: [Int64] = rows.compactMap { row in
                let createdAt: Date = row[ClipItem.Columns.createdAt.name]
                let lastUsedAt: Date? = row[ClipItem.Columns.lastUsedAt.name]
                guard ClipItem.effectiveTimestamp(createdAt: createdAt, lastUsedAt: lastUsedAt) < cutoff
                else { return nil }
                return row[ClipItem.Columns.id.name]
            }
            guard !ids.isEmpty else { return [] }
            let victims = try ClipItem.fetchAll(db, keys: ids)
            try ClipItem.deleteAll(db, keys: ids)
            return victims
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

    /// Deletes every unpinned item. Returns the deleted items (so callers can
    /// archive their text).
    @discardableResult
    func clearAll() throws -> [ClipItem] {
        let victims: [ClipItem] = try dbQueue.write { db in
            let items = try ClipItem.filter(ClipItem.Columns.pinned == false).fetchAll(db)
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
