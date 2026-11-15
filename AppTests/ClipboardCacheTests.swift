import XCTest
@testable import AppCore

@MainActor
final class ClipboardCacheTests: XCTestCase {

    private func makeCache() throws -> (ClipboardCache, ClipboardRepository) {
        let db = try AppDatabase(inMemory: true)
        let repo = ClipboardRepository(database: db)
        let cache = ClipboardCache(repository: repo)
        return (cache, repo)
    }

    private func textItem(_ text: String, app: String? = nil, hash: String) -> ClipItem {
        ClipItem(id: nil, kind: .text, textContent: text, imagePath: nil,
                 imageWidth: nil, imageHeight: nil, previewText: String(text.prefix(200)),
                 sourceApp: app, createdAt: Date(), pinned: false, contentHash: hash, lastUsedAt: nil)
    }

    func testFilterMatchesContentPreviewAndApp() throws {
        let (cache, repo) = try makeCache()
        let a = try XCTUnwrap(try repo.insertIfNew(textItem("hello world", app: "com.apple.Notes", hash: "h1")))
        _ = try repo.insertIfNew(textItem("goodbye", app: "com.apple.Safari", hash: "h2"))
        cache.loadAll()

        XCTAssertEqual(cache.filter("hello").map(\.id), [a.id])
        XCTAssertEqual(cache.filter("notes").map(\.id), [a.id])   // by app name substring
        XCTAssertEqual(cache.filter("zzz").count, 0)
    }

    func testFilterIsCaseInsensitiveWithMixedCaseQueries() throws {
        let (cache, repo) = try makeCache()
        let a = try XCTUnwrap(try repo.insertIfNew(textItem("Hello World", app: "com.apple.Notes", hash: "h1")))
        let b = try XCTUnwrap(try repo.insertIfNew(textItem("Straße", hash: "h2")))
        cache.loadAll()

        XCTAssertEqual(cache.filter("hELLO wOrLd").map(\.id), [a.id])
        XCTAssertEqual(cache.filter("NOTES").map(\.id), [a.id])
        XCTAssertEqual(cache.filter("STRASSE").count, 0, "ß is not folded to ss (lowercased() semantics)")
        XCTAssertEqual(cache.filter("STRAßE").map(\.id), [b.id])
    }

    func testFilterSeesItemsAddedAfterAnEarlierSearch() throws {
        let (cache, _) = try makeCache()
        cache.insertNew(textItem("alpha", hash: "a").withID(1))
        XCTAssertEqual(cache.filter("Beta").count, 0)
        cache.insertNew(textItem("BETA", hash: "b").withID(2))
        XCTAssertEqual(cache.filter("beta").map(\.id), [2])
        cache.remove(id: 2)
        XCTAssertEqual(cache.filter("beta").count, 0)
    }

    func testLargeTextStrippedButFetchable() throws {
        let (cache, repo) = try makeCache()
        let big = String(repeating: "x", count: 4096) // > 3 KB threshold
        let inserted = try XCTUnwrap(try repo.insertIfNew(textItem(big, hash: "big")))
        cache.loadAll()
        let cached = try XCTUnwrap(cache.items.first { $0.id == inserted.id })
        XCTAssertNil(cached.textContent, "Large text should be stripped from the cache")
        XCTAssertEqual(cache.fullText(for: cached), big, "Full text should be fetchable from the repo")
    }

    func testInsertNewIsNewestFirst() throws {
        let (cache, _) = try makeCache()
        cache.insertNew(textItem("first", hash: "a").withID(1))
        cache.insertNew(textItem("second", hash: "b").withID(2))
        XCTAssertEqual(cache.items.first?.id, 2)
    }

    func testBumpLastUsedMovesToTop() throws {
        let (cache, _) = try makeCache()
        cache.insertNew(textItem("first", hash: "a").withID(1))
        cache.insertNew(textItem("second", hash: "b").withID(2))
        cache.bumpLastUsed(id: 1)
        XCTAssertEqual(cache.items.first?.id, 1)
    }

    func testPinnedSortsAbove() throws {
        let (cache, _) = try makeCache()
        cache.insertNew(textItem("first", hash: "a").withID(1))
        cache.insertNew(textItem("second", hash: "b").withID(2))
        cache.togglePinned(id: 1)
        XCTAssertEqual(cache.items.first?.id, 1, "Pinned item should sort above newer unpinned")
    }
}

private extension ClipItem {
    func withID(_ id: Int64) -> ClipItem {
        var copy = self
        copy.id = id
        return copy
    }
}
