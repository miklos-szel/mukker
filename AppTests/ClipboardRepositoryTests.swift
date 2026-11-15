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

    func testSetRichTextPathUpdatesExistingRow() throws {
        let repo = try makeRepo()
        let item = try XCTUnwrap(try repo.insertIfNew(textItem("plain first", createdAt: Date(), hash: "pf")))
        let id = try XCTUnwrap(item.id)

        try repo.setRichTextPath(id: id, path: "/tmp/pf.rtf")
        XCTAssertEqual(try repo.fetchOne(id: id)?.richTextPath, "/tmp/pf.rtf")
        XCTAssertEqual(try repo.fetchOne(id: id)?.textContent, "plain first", "only the path changes")

        try repo.setRichTextPath(id: id, path: nil)
        XCTAssertNil(try repo.fetchOne(id: id)?.richTextPath)
    }

    func testOrphanSweepDeletesOnlyUnreferencedFiles() throws {
        let repo = try makeRepo()
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mukker-test-\(UUID().uuidString)", isDirectory: true)
        let images = root.appendingPathComponent("images", isDirectory: true)
        let rich = root.appendingPathComponent("richtext", isDirectory: true)
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        try fm.createDirectory(at: rich, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func file(_ dir: URL, _ name: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            return url
        }
        let keptImage = try file(images, "aaa.png")
        let keptRTF = try file(rich, "bbb.rtf")
        let orphanImage = try file(images, "ccc.png")
        let orphanRTF = try file(rich, "ddd.rtf")

        var image = textItem("", kind: .image, createdAt: Date(), hash: "aaa")
        image.imagePath = keptImage.path
        var text = textItem("rich", createdAt: Date(), hash: "bbb")
        text.richTextPath = keptRTF.path
        _ = try repo.insertIfNew(image)
        _ = try repo.insertIfNew(text)

        let removed = try repo.removeOrphanedSidecarFiles(in: [images, rich])

        XCTAssertEqual(removed, 2)
        XCTAssertTrue(fm.fileExists(atPath: keptImage.path))
        XCTAssertTrue(fm.fileExists(atPath: keptRTF.path))
        XCTAssertFalse(fm.fileExists(atPath: orphanImage.path))
        XCTAssertFalse(fm.fileExists(atPath: orphanRTF.path))
    }

    func testPurgeReturnsFullDeletedRowsAndRemovesTheirSidecars() throws {
        let repo = try makeRepo()
        let now = Date()
        let rtfPath = try makeTempFile(named: "expired.rtf")
        var expired = textItem("expired text", createdAt: now.addingTimeInterval(-10_000), hash: "e")
        expired.richTextPath = rtfPath
        expired.sourceApp = "com.apple.Notes"
        let inserted = try XCTUnwrap(try repo.insertIfNew(expired))
        // Old but recently used: its effective timestamp is fresh, so it survives.
        let used = try XCTUnwrap(try repo.insertIfNew(textItem("used", createdAt: now.addingTimeInterval(-10_000), hash: "u")))
        try repo.bumpLastUsed(id: try XCTUnwrap(used.id))
        // Another kind past the cutoff is untouched by a text purge.
        var image = textItem("", kind: .image, createdAt: now.addingTimeInterval(-10_000), hash: "i")
        image.imagePath = try makeTempFile(named: "kept.png")
        _ = try repo.insertIfNew(image)

        let removed = try repo.purgeOlderThan(kind: .text, cutoff: now.addingTimeInterval(-3600))

        XCTAssertEqual(removed.map(\.id), [inserted.id])
        let row = try XCTUnwrap(removed.first)
        XCTAssertEqual(row.textContent, "expired text", "the full row, text included, for archiving")
        XCTAssertEqual(row.sourceApp, "com.apple.Notes")
        XCTAssertEqual(row.richTextPath, rtfPath)
        XCTAssertEqual(row.contentHash, "e")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rtfPath), "purge should remove the RTF")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(image.imagePath)))
        XCTAssertEqual(Set(try repo.recent().map(\.contentHash)), ["u", "i"])
        XCTAssertEqual(try repo.purgeOlderThan(kind: .text, cutoff: now.addingTimeInterval(-3600)), [])
    }

    func testFetchOneByContentHashFindsDuplicate() throws {
        let repo = try makeRepo()
        let first = try XCTUnwrap(try repo.insertIfNew(textItem("dup", createdAt: Date(), hash: "d")))
        XCTAssertNil(try repo.insertIfNew(textItem("dup", createdAt: Date(), hash: "d")), "same hash must not insert")
        let found = try XCTUnwrap(try repo.fetchOne(contentHash: "d"))
        XCTAssertEqual(found.id, first.id)
    }
}
