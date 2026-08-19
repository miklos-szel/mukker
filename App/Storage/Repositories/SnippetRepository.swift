import Foundation
import GRDB

final class SnippetRepository {
    private let dbQueue: DatabaseQueue

    init(database: AppDatabase = .shared) {
        self.dbQueue = database.dbQueue
    }

    // MARK: Collections

    func allCollections() throws -> [SnippetCollection] {
        try dbQueue.read { db in
            try SnippetCollection
                .order(SnippetCollection.Columns.name.asc)
                .fetchAll(db)
        }
    }

    @discardableResult
    func createCollection(name: String,
                          keywordPrefix: String = "",
                          keywordSuffix: String = "") throws -> SnippetCollection {
        try dbQueue.write { db in
            var c = SnippetCollection(
                id: nil,
                name: name,
                keywordPrefix: keywordPrefix,
                keywordSuffix: keywordSuffix,
                createdAt: Date()
            )
            try c.insert(db)
            return c
        }
    }

    func renameCollection(id: Int64, name: String) throws {
        try dbQueue.write { db in
            guard var c = try SnippetCollection.fetchOne(db, key: id) else { return }
            c.name = name
            try c.update(db)
        }
    }

    func deleteCollection(id: Int64) throws {
        _ = try dbQueue.write { db in
            try SnippetCollection.deleteOne(db, key: id)
        }
    }

    // MARK: Snippets

    func snippets(in collectionId: Int64) throws -> [Snippet] {
        try dbQueue.read { db in
            try Snippet
                .filter(Snippet.Columns.collectionId == collectionId)
                .order(Snippet.Columns.name.asc)
                .fetchAll(db)
        }
    }

    func allSnippets() throws -> [Snippet] {
        try dbQueue.read { db in
            try Snippet
                .order(Snippet.Columns.name.asc)
                .fetchAll(db)
        }
    }

    /// Filters on snippet name only (case-insensitive).
    func search(query: String, in collectionId: Int64? = nil) throws -> [Snippet] {
        guard !query.isEmpty else {
            if let c = collectionId { return try snippets(in: c) }
            return try allSnippets()
        }
        let like = "%\(query.lowercased())%"
        return try dbQueue.read { db in
            var request = Snippet.filter(sql: "LOWER(name) LIKE ?", arguments: [like])
            if let cid = collectionId {
                request = request.filter(Snippet.Columns.collectionId == cid)
            }
            return try request.order(Snippet.Columns.name.asc).fetchAll(db)
        }
    }

    @discardableResult
    func createSnippet(collectionId: Int64,
                       name: String,
                       keyword: String?,
                       content: String,
                       uid: String? = nil) throws -> Snippet {
        try dbQueue.write { db in
            let now = Date()
            var s = Snippet(
                id: nil,
                collectionId: collectionId,
                name: name,
                keyword: keyword,
                content: content,
                uid: uid ?? UUID().uuidString,
                createdAt: now,
                updatedAt: now
            )
            try s.insert(db)
            return s
        }
    }

    /// No-op when the row no longer exists (e.g. the editor autosaves a draft
    /// of a snippet that was deleted while open) — never resurrects rows.
    func updateSnippet(_ snippet: Snippet) throws {
        try dbQueue.write { db in
            guard let id = snippet.id, try Snippet.exists(db, key: id) else { return }
            var s = snippet
            s.updatedAt = Date()
            try s.update(db)
        }
    }

    func deleteSnippet(id: Int64) throws {
        _ = try dbQueue.write { db in
            try Snippet.deleteOne(db, key: id)
        }
    }

    /// Bulk import a collection with snippets in one transaction.
    /// If a snippet with the same `uid` already exists in the collection, it is updated instead.
    @discardableResult
    func importCollection(name: String,
                          keywordPrefix: String,
                          keywordSuffix: String,
                          snippets incoming: [(name: String, keyword: String?, content: String, uid: String?)]) throws -> SnippetCollection {
        try dbQueue.write { db in
            // Find or create the collection by name
            let existing = try SnippetCollection
                .filter(SnippetCollection.Columns.name == name)
                .fetchOne(db)
            var collection: SnippetCollection
            if let e = existing {
                collection = e
                collection.keywordPrefix = keywordPrefix
                collection.keywordSuffix = keywordSuffix
                try collection.update(db)
            } else {
                collection = SnippetCollection(
                    id: nil,
                    name: name,
                    keywordPrefix: keywordPrefix,
                    keywordSuffix: keywordSuffix,
                    createdAt: Date()
                )
                try collection.insert(db)
            }

            guard let cid = collection.id else { return collection }

            for snip in incoming {
                let now = Date()
                if let uid = snip.uid,
                   let existingSnippet = try Snippet
                    .filter(Snippet.Columns.collectionId == cid)
                    .filter(Snippet.Columns.uid == uid)
                    .fetchOne(db) {
                    var update = existingSnippet
                    update.name = snip.name
                    update.keyword = snip.keyword
                    update.content = snip.content
                    update.updatedAt = now
                    try update.update(db)
                } else {
                    var s = Snippet(
                        id: nil,
                        collectionId: cid,
                        name: snip.name,
                        keyword: snip.keyword,
                        content: snip.content,
                        uid: snip.uid ?? UUID().uuidString,
                        createdAt: now,
                        updatedAt: now
                    )
                    try s.insert(db)
                }
            }
            return collection
        }
    }
}
