import XCTest
@testable import AppCore

@MainActor
final class SnippetSearchTests: XCTestCase {

    private func makeCache() throws -> (SnippetCache, SnippetRepository, Int64) {
        let db = try AppDatabase(inMemory: true)
        let repo = SnippetRepository(database: db)
        let collection = try repo.createCollection(name: "Test")
        let cid = try XCTUnwrap(collection.id)
        // binlog_time's CONTENT contains "select"; its NAME does not.
        try repo.createSnippet(collectionId: cid, name: "binlog_time", keyword: nil,
                               content: "select from_unixtime(mytimestamp);")
        try repo.createSnippet(collectionId: cid, name: "disk", keyword: nil, content: "du -hs .")
        try repo.createSnippet(collectionId: cid, name: "disk3", keyword: nil, content: "du -smh *")
        try repo.createSnippet(collectionId: cid, name: "date helper", keyword: "dt", content: "{date}")
        let cache = SnippetCache(repository: repo)
        cache.loadAll()
        return (cache, repo, cid)
    }

    func testTitleOnly_contentIsNotMatched() throws {
        let (cache, _, _) = try makeCache()
        // "select" only appears in binlog_time's CONTENT → must NOT match (title-only contract).
        XCTAssertTrue(cache.filterByName("select", in: nil).isEmpty)
    }

    func testMatchesByName() throws {
        let (cache, _, _) = try makeCache()
        let names = cache.filterByName("disk", in: nil).map(\.name)
        XCTAssertEqual(Set(names), ["disk", "disk3"])
    }

    func testMatchesByKeyword() throws {
        let (cache, _, _) = try makeCache()
        let names = cache.filterByName("dt", in: nil).map(\.name)
        XCTAssertEqual(names, ["date helper"])
    }

    func testMixedCaseQueriesMatchNameAndKeyword() throws {
        let (cache, _, cid) = try makeCache()
        XCTAssertEqual(Set(cache.filterByName("DiSk", in: nil).map(\.name)), ["disk", "disk3"])
        XCTAssertEqual(cache.filterByName("DT", in: cid).map(\.name), ["date helper"])
        XCTAssertEqual(cache.filterByName("Date HELPER", in: nil).map(\.name), ["date helper"])
    }

    func testSingleQueryLoadGroupsAndOrdersPerCollection() throws {
        let (cache, repo, cid) = try makeCache()
        let other = try XCTUnwrap(try repo.createCollection(name: "Another").id)
        try repo.createSnippet(collectionId: other, name: "zeta", keyword: nil, content: "z")
        try repo.createSnippet(collectionId: other, name: "alpha", keyword: nil, content: "a")
        try repo.createSnippet(collectionId: other, name: "alpha", keyword: nil, content: "a2")
        cache.loadAll()

        XCTAssertEqual(cache.collections.map(\.name), ["Another", "Test"])
        for collection in [cid, other] {
            XCTAssertEqual(cache.snippets(in: collection).map(\.id), try repo.snippets(in: collection).map(\.id),
                           "grouped order must match the per-collection query")
        }
        XCTAssertEqual(cache.snippets(in: other).map(\.content), ["a", "a2", "z"])
        XCTAssertEqual(cache.snippets(in: nil).count, 7)
        XCTAssertEqual(cache.filterByName("ALPHA", in: other).count, 2)
    }

    func testEmptyQueryReturnsAll() throws {
        let (cache, _, _) = try makeCache()
        XCTAssertEqual(cache.filterByName("", in: nil).count, 4)
    }
}
