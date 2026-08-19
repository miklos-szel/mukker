import Foundation
import GRDB

final class AppDatabase {
    let dbQueue: DatabaseQueue

    static let shared: AppDatabase = {
        do {
            return try AppDatabase(url: AppPaths.databaseURL)
        } catch {
            Log.db.error("Failed to open database: \(error.localizedDescription)")
            fatalError("Could not open database: \(error)")
        }
    }()

    init(url: URL) throws {
        var config = Configuration()
        config.label = "AppDatabase"
        self.dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try migrator.migrate(dbQueue)
    }

    /// In-memory database for tests. `inMemory` must be true — on-disk
    /// databases go through `init(url:)`.
    init(inMemory: Bool) throws {
        precondition(inMemory, "Use init(url:) for on-disk databases")
        var config = Configuration()
        config.label = "AppDatabase.Memory"
        self.dbQueue = try DatabaseQueue(configuration: config)
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            try db.create(table: "clip_items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("textContent", .text)
                t.column("imagePath", .text)
                t.column("imageWidth", .integer)
                t.column("imageHeight", .integer)
                t.column("previewText", .text)
                t.column("sourceApp", .text)
                t.column("createdAt", .double).notNull()
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("contentHash", .text).notNull()
            }
            try db.create(index: "idx_clip_created", on: "clip_items", columns: ["createdAt"])
            try db.create(index: "idx_clip_hash", on: "clip_items", columns: ["contentHash"])

            try db.create(table: "collections") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("keywordPrefix", .text).notNull().defaults(to: "")
                t.column("keywordSuffix", .text).notNull().defaults(to: "")
                t.column("createdAt", .double).notNull()
            }

            try db.create(table: "snippets") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("collectionId", .integer)
                    .notNull()
                    .references("collections", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("keyword", .text)
                t.column("content", .text).notNull()
                t.column("uid", .text)
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }
            try db.create(index: "idx_snip_collection", on: "snippets", columns: ["collectionId"])
        }

        m.registerMigration("v2_lastUsed") { db in
            try db.alter(table: "clip_items") { t in
                t.add(column: "lastUsedAt", .double)
            }
            try db.create(index: "idx_clip_lastUsed", on: "clip_items", columns: ["lastUsedAt"])
        }

        m.registerMigration("v3_richText") { db in
            try db.alter(table: "clip_items") { t in
                t.add(column: "richTextPath", .text)
            }
        }

        return m
    }
}
