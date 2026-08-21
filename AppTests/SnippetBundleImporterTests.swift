import XCTest
@testable import AppCore

final class SnippetBundleImporterTests: XCTestCase {

    private var fixtureURL: URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/test.alfredsnippets")
    }

    func testParsesProvidedFixture() throws {
        let importer = SnippetBundleImporter()
        let collection = try importer.parse(url: fixtureURL)

        XCTAssertEqual(collection.name, "test")
        XCTAssertEqual(collection.keywordPrefix, "")
        XCTAssertEqual(collection.keywordSuffix, "")
        XCTAssertEqual(collection.snippets.count, 3)

        let byName = Dictionary(uniqueKeysWithValues: collection.snippets.map { ($0.name, $0) })

        let datum = try XCTUnwrap(byName["datum"])
        XCTAssertEqual(datum.keyword, "date")
        XCTAssertEqual(datum.content, "{date}")
        XCTAssertEqual(datum.uid, "AA74F388-B619-430B-B655-8020BA9A84C4")

        let binlog = try XCTUnwrap(byName["binlog_time"])
        XCTAssertNil(binlog.keyword)
        XCTAssertEqual(binlog.content, "select from_unixtime(mytimestamp);")
        XCTAssertEqual(binlog.uid, "937AA1A4-B12E-4329-AAA2-33B07EE13FD9")

        let disk = try XCTUnwrap(byName["disk"])
        XCTAssertNil(disk.keyword)
        XCTAssertEqual(disk.content, "while [ 1 ] ;do du -hs . ;date ;sleep 10; done")
        XCTAssertEqual(disk.uid, "39861F68-6D03-4F10-8286-DB115BF66830")
    }

    func testRoundTripThroughRepository() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = SnippetRepository(database: db)
        let parsed = try SnippetBundleImporter().parse(url: fixtureURL)

        let snippets = parsed.snippets.map {
            (name: $0.name, keyword: $0.keyword, content: $0.content, uid: $0.uid)
        }
        let collection = try repo.importCollection(
            name: parsed.name,
            keywordPrefix: parsed.keywordPrefix,
            keywordSuffix: parsed.keywordSuffix,
            snippets: snippets
        )
        let cid = try XCTUnwrap(collection.id)

        let stored = try repo.snippets(in: cid)
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(Set(stored.map { $0.name }), ["datum", "binlog_time", "disk"])

        // Re-import — should be idempotent thanks to uid matching.
        _ = try repo.importCollection(
            name: parsed.name,
            keywordPrefix: parsed.keywordPrefix,
            keywordSuffix: parsed.keywordSuffix,
            snippets: snippets
        )
        let storedAgain = try repo.snippets(in: cid)
        XCTAssertEqual(storedAgain.count, 3, "Re-import must not create duplicates")
    }

    func testMukkerExportImportRoundTrip() throws {
        let db = try AppDatabase(inMemory: true)
        let repo = SnippetRepository(database: db)
        let parsed = try SnippetBundleImporter().parse(url: fixtureURL)
        let snippets = parsed.snippets.map {
            (name: $0.name, keyword: $0.keyword, content: $0.content, uid: $0.uid)
        }
        _ = try repo.importCollection(
            name: parsed.name,
            keywordPrefix: parsed.keywordPrefix,
            keywordSuffix: parsed.keywordSuffix,
            snippets: snippets
        )

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mukker-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: exportURL) }

        try MukkerExporter(repository: repo).export(collectionIds: nil, to: exportURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        let importDB = try AppDatabase(inMemory: true)
        let importRepo = SnippetRepository(database: importDB)
        let imported = try MukkerImporter(repository: importRepo).importFile(at: exportURL)
        XCTAssertEqual(imported.count, 1)
        let cid = try XCTUnwrap(imported.first?.id)
        let importedSnippets = try importRepo.snippets(in: cid)
        XCTAssertEqual(importedSnippets.count, 3)
    }
}
