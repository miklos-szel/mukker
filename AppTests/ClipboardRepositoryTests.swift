import XCTest
@testable import AppCore

final class ClipboardRepositoryTests: XCTestCase {

    private func makeRepo() throws -> ClipboardRepository {
        let db = try AppDatabase(inMemory: true)
        return ClipboardRepository(database: db)
    }

    private func textItem(_ text: String, kind: ClipKind = .text, createdAt: Date,
                          pinned: Bool = false, hash: String) -> ClipItem {
        ClipItem(id: nil, kind: kind, textContent: text, imagePath: nil,
                 imageWidth: nil, imageHeight: nil, previewText: text,
                 sourceApp: nil, createdAt: createdAt, pinned: pinned,
                 contentHash: hash, lastUsedAt: nil)
    }

    func testRecentOrdersByLastUsedThenCreated() throws {
        let repo = try makeRepo()
        let now = Date()
        let older = try XCTUnwrap(try repo.insertIfNew(textItem("older", createdAt: now.addingTimeInterval(-100), hash: "o")))
        _ = try repo.insertIfNew(textItem("newer", createdAt: now, hash: "n"))

        // Initially "newer" is first.
        XCTAssertEqual(try repo.recent().first?.contentHash, "n")

        // Bump the older one — it should move to the top via lastUsedAt.
        try repo.bumpLastUsed(id: try XCTUnwrap(older.id))
        XCTAssertEqual(try repo.recent().first?.contentHash, "o")
    }

    func testPurgeOlderThanDeletesOnlyMatchingUnpinned() throws {
        let repo = try makeRepo()
        let now = Date()
        let old = try XCTUnwrap(try repo.insertIfNew(textItem("old", createdAt: now.addingTimeInterval(-10_000), hash: "old")))
        let pinnedOld = try XCTUnwrap(try repo.insertIfNew(textItem("pinnedOld", createdAt: now.addingTimeInterval(-10_000), pinned: true, hash: "pin")))
        let fresh = try XCTUnwrap(try repo.insertIfNew(textItem("fresh", createdAt: now, hash: "fresh")))

        let cutoff = now.addingTimeInterval(-3600)
        try repo.purgeOlderThan(kind: .text, cutoff: cutoff)

        let remaining = try repo.recent().compactMap(\.id)
        XCTAssertFalse(remaining.contains(try XCTUnwrap(old.id)), "old unpinned should be purged")
        XCTAssertTrue(remaining.contains(try XCTUnwrap(pinnedOld.id)), "pinned should survive")
        XCTAssertTrue(remaining.contains(try XCTUnwrap(fresh.id)), "fresh should survive")
    }

    func testRichTextPathRoundTripsAndDefaultsNil() throws {
        let repo = try makeRepo()
        // Plain capture leaves richTextPath nil.
        let plain = try XCTUnwrap(try repo.insertIfNew(textItem("plain", createdAt: Date(), hash: "p")))
        XCTAssertNil(try XCTUnwrap(try repo.fetchOne(id: try XCTUnwrap(plain.id))).richTextPath)

        // A rich item persists and reloads its path.
        var rich = textItem("bold", createdAt: Date(), hash: "r")
        rich.richTextPath = "/tmp/r.rtf"
        let inserted = try XCTUnwrap(try repo.insertIfNew(rich))
        let reloaded = try XCTUnwrap(try repo.fetchOne(id: try XCTUnwrap(inserted.id)))
        XCTAssertEqual(reloaded.richTextPath, "/tmp/r.rtf")
    }

    func testUpdateTextContentRewritesContentAndHash() throws {
        let repo = try makeRepo()
        let item = try XCTUnwrap(try repo.insertIfNew(textItem("hello", createdAt: Date(), hash: "h")))
        let id = try XCTUnwrap(item.id)
        try repo.updateTextContent(id: id, newContent: "hello world", newHash: "h2")
        let reloaded = try XCTUnwrap(try repo.fetchOne(id: id))
        XCTAssertEqual(reloaded.textContent, "hello world")
        XCTAssertEqual(reloaded.contentHash, "h2")
    }

    /// Creates a real temp file and returns its path.
    private func makeTempFile(named name: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mukker-test-\(UUID().uuidString)-\(name)")
        try Data("x".utf8).write(to: url)
        return url.path
    }

    func testUpdateTextContentClearsStaleRichText() throws {
        let repo = try makeRepo()
        let rtfPath = try makeTempFile(named: "old.rtf")
        var rich = textItem("formatted", createdAt: Date(), hash: "r1")
        rich.richTextPath = rtfPath
        let inserted = try XCTUnwrap(try repo.insertIfNew(rich))
        let id = try XCTUnwrap(inserted.id)

        try repo.updateTextContent(id: id, newContent: "formatted plus more", newHash: "r2")

        let reloaded = try XCTUnwrap(try repo.fetchOne(id: id))
        XCTAssertNil(reloaded.richTextPath, "merged content no longer matches the stored RTF")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rtfPath), "orphaned RTF should be deleted")
    }

    func testTrimDeletesLeastRecentlyUsedNotOldestCreated() throws {
        let repo = try makeRepo()
        let now = Date()
        let oldButUsed = try XCTUnwrap(try repo.insertIfNew(textItem("oldUsed", createdAt: now.addingTimeInterval(-10_000), hash: "a")))
        _ = try repo.insertIfNew(textItem("middle", createdAt: now.addingTimeInterval(-5_000), hash: "b"))
        _ = try repo.insertIfNew(textItem("fresh", createdAt: now, hash: "c"))

        // The oldest-created item was just used — it sits at the top of history.
        try repo.bumpLastUsed(id: try XCTUnwrap(oldButUsed.id))

        let victims = try repo.trim(to: 2)
        XCTAssertEqual(victims.map(\.contentHash), ["b"], "trim must follow the effective (last-used) order")
        let remaining = try repo.recent().map(\.contentHash)
        XCTAssertTrue(remaining.contains("a"), "recently used item must survive the trim")
    }

    func testDeletionPathsRemoveSidecarFiles() throws {
        let repo = try makeRepo()
        let imagePath = try makeTempFile(named: "img.png")
        let rtfPath = try makeTempFile(named: "text.rtf")

        var image = textItem("", kind: .image, createdAt: Date(), hash: "img")
        image.imagePath = imagePath
        var rich = textItem("rich", createdAt: Date(), hash: "rich")
        rich.richTextPath = rtfPath

        let insertedImage = try XCTUnwrap(try repo.insertIfNew(image))
        _ = try XCTUnwrap(try repo.insertIfNew(rich))

        try repo.delete(id: try XCTUnwrap(insertedImage.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath), "delete(id:) should remove the PNG")

        let cleared = try repo.clearAll(keepPinned: true)
        XCTAssertEqual(cleared.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rtfPath), "clearAll should remove the RTF")
    }

    func testFetchOneByContentHashFindsDuplicate() throws {
        let repo = try makeRepo()
        let first = try XCTUnwrap(try repo.insertIfNew(textItem("dup", createdAt: Date(), hash: "d")))
        XCTAssertNil(try repo.insertIfNew(textItem("dup", createdAt: Date(), hash: "d")), "same hash must not insert")
        let found = try XCTUnwrap(try repo.fetchOne(contentHash: "d"))
        XCTAssertEqual(found.id, first.id)
    }
}
