import GRDB
import XCTest
@testable import AppCore

final class DatabaseMigrationTests: XCTestCase {

    func testFreshDatabaseHasHistoryOrderIndex() throws {
        let db = try AppDatabase(inMemory: true)
        let sql = try db.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_clip_order'")
        }
        let definition = try XCTUnwrap(sql)
        XCTAssertTrue(definition.contains("clip_items"))
        XCTAssertTrue(definition.contains("COALESCE(lastUsedAt, createdAt)"))
        // The older single-column indexes stay.
        let names = try db.dbQueue.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        XCTAssertTrue(names.isSuperset(of: ["idx_clip_created", "idx_clip_hash", "idx_clip_lastUsed", "idx_clip_order"]))
    }

    /// The history and trim queries must be served by the index rather than a
    /// full-table sort (the SQL text matches `ClipboardRepository.recent`/`trim`).
    func testOrderingQueriesUseTheIndex() throws {
        let db = try AppDatabase(inMemory: true)
        func plan(_ sql: String) throws -> String {
            try db.dbQueue.read { db in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql)
                    .map { $0["detail"] as String }
                    .joined(separator: "\n")
            }
        }
        let recent = try plan("SELECT * FROM clip_items ORDER BY pinned DESC, COALESCE(lastUsedAt, createdAt) DESC LIMIT 500")
        XCTAssertTrue(recent.contains("idx_clip_order"), recent)
        XCTAssertFalse(recent.contains("TEMP B-TREE"), recent)

        let trim = try plan("SELECT * FROM clip_items WHERE pinned = 0 ORDER BY COALESCE(lastUsedAt, createdAt) ASC LIMIT 10")
        XCTAssertTrue(trim.contains("idx_clip_order"), trim)
        XCTAssertFalse(trim.contains("TEMP B-TREE"), trim)
    }
}
