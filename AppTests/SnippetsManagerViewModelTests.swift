import XCTest
@testable import AppCore

@MainActor
final class SnippetsManagerViewModelTests: XCTestCase {

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/test.alfredsnippets")
    }

    private func makeViewModel() throws -> (SnippetsManagerViewModel, SnippetRepository) {
        let db = try AppDatabase(inMemory: true)
        let repo = SnippetRepository(database: db)
        let cache = SnippetCache(repository: repo)
        let vm = SnippetsManagerViewModel(repository: repo, snippetCache: cache)
        return (vm, repo)
    }

    func testRenameRejectsEmptyAndWhitespaceNames() throws {
        let (vm, repo) = try makeViewModel()
        let collection = try repo.createCollection(name: "Work")
        vm.reload()

        XCTAssertFalse(vm.renameCollection(collection, to: ""))
        XCTAssertFalse(vm.renameCollection(collection, to: "  \n\t "))
        XCTAssertEqual(try repo.allCollections().map(\.name), ["Work"])
        XCTAssertNil(vm.renamingCollectionId, "a rejected rename still ends editing")
    }

    func testRenameTrimsName() throws {
        let (vm, repo) = try makeViewModel()
        let collection = try repo.createCollection(name: "Work")
        vm.reload()

        XCTAssertTrue(vm.renameCollection(collection, to: "  Personal  "))
        XCTAssertEqual(try repo.allCollections().map(\.name), ["Personal"])
    }

    func testNewCollectionStartsInRenameMode() throws {
        let (vm, _) = try makeViewModel()
        vm.createCollection()
        XCTAssertNotNil(vm.renamingCollectionId)
        XCTAssertEqual(vm.renamingCollectionId, vm.selectedCollectionId)
    }

    func testBundleImportReportsCountAndSelectsCollection() throws {
        let (vm, _) = try makeViewModel()
        let summary = try XCTUnwrap(vm.importSnippetBundle(url: fixtureURL))
        XCTAssertEqual(summary.snippetCount, 3)
        XCTAssertEqual(summary.collectionNames, ["test"])
        XCTAssertEqual(summary.message, "Imported 3 snippets into “test”.")
        XCTAssertEqual(vm.collections.first(where: { $0.id == vm.selectedCollectionId })?.name, "test")
        XCTAssertNotNil(vm.notice)
        XCTAssertNil(vm.errorMessage)
    }

    func testNativeImportReportsCountAndSelectsCollection() throws {
        let (source, sourceRepo) = try makeViewModel()
        source.importSnippetBundle(url: fixtureURL)
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        try MukkerExporter(repository: sourceRepo).export(collectionIds: nil, to: exportURL)

        let (vm, _) = try makeViewModel()
        let summary = try XCTUnwrap(vm.importFromMukker(url: exportURL))
        XCTAssertEqual(summary.snippetCount, 3)
        XCTAssertEqual(vm.collections.first(where: { $0.id == vm.selectedCollectionId })?.name, "test")
    }
}
