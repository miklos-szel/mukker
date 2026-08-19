import XCTest
@testable import AppCore

@MainActor
final class PopupViewModelTests: XCTestCase {

    private func makeViewModel() throws -> (PopupViewModel, SnippetCollection) {
        let db = try AppDatabase(inMemory: true)

        let snippetRepo = SnippetRepository(database: db)
        let collection = try snippetRepo.createCollection(name: "Coll")
        let cid = try XCTUnwrap(collection.id)
        try snippetRepo.createSnippet(collectionId: cid, name: "select_helper", keyword: nil, content: "SELECT 1")
        try snippetRepo.createSnippet(collectionId: cid, name: "other", keyword: nil, content: "nothing")
        let snippetCache = SnippetCache(repository: snippetRepo)
        snippetCache.loadAll()

        let clipRepo = ClipboardRepository(database: db)
        _ = try clipRepo.insertIfNew(ClipItem(id: nil, kind: .text, textContent: "select from t",
                                              imagePath: nil, imageWidth: nil, imageHeight: nil,
                                              previewText: "select from t", sourceApp: "com.apple.Notes",
                                              createdAt: Date(), pinned: false, contentHash: "c1", lastUsedAt: nil))
        _ = try clipRepo.insertIfNew(ClipItem(id: nil, kind: .text, textContent: "unrelated",
                                              imagePath: nil, imageWidth: nil, imageHeight: nil,
                                              previewText: "unrelated", sourceApp: "com.apple.Notes",
                                              createdAt: Date(), pinned: false, contentHash: "c2", lastUsedAt: nil))
        let clipCache = ClipboardCache(repository: clipRepo)
        clipCache.loadAll()

        let vm = PopupViewModel(snippetCache: snippetCache, clipboardCache: clipCache)
        return (vm, collection)
    }

    func testEmptyQueryListsCollectionsThenClips() throws {
        let (vm, _) = try makeViewModel()
        vm.reset()
        // Snippet section at top level shows collections.
        XCTAssertEqual(vm.snippetResults.count, 1)
        if case .collection = vm.snippetResults.first { } else { XCTFail("Expected a collection row first") }
        XCTAssertEqual(vm.clipResults.count, 2)
        // First overall result is selected.
        XCTAssertEqual(vm.selectedId, vm.results.first?.id)
    }

    func testQueryFiltersSnippetsByTitleAndClipsByContent() throws {
        let (vm, _) = try makeViewModel()
        vm.query = "select"
        // Snippet matched by NAME ("select_helper"); the "other" snippet (content has none) excluded.
        XCTAssertEqual(vm.snippetResults.count, 1)
        if case .snippet(let s) = vm.snippetResults.first { XCTAssertEqual(s.name, "select_helper") }
        else { XCTFail("Expected select_helper snippet") }
        // Clip matched by content.
        XCTAssertEqual(vm.clipResults.count, 1)
    }

    func testEnterAndExitCollection() throws {
        let (vm, collection) = try makeViewModel()
        vm.enter(collection)
        XCTAssertEqual(vm.currentCollection?.id, collection.id)
        // Inside the collection, empty query lists its snippets.
        XCTAssertEqual(vm.snippetResults.count, 2)
        XCTAssertTrue(vm.exitCollection())
        XCTAssertNil(vm.currentCollection)
    }

    func testConfirmCollectionDrillsInWithoutClosing() throws {
        let (vm, _) = try makeViewModel()
        vm.reset()
        // First row is the collection.
        let shouldClose = vm.confirmSelection()
        XCTAssertFalse(shouldClose, "Drilling into a collection must not close the popup")
        XCTAssertNotNil(vm.currentCollection)
    }

    func testCancelRequestsClose() throws {
        let (vm, _) = try makeViewModel()
        var closed = false
        vm.onRequestClose = { closed = true }
        vm.cancel()
        XCTAssertTrue(closed)
    }

    func testHistoryPagingAndSearchAcrossAll() throws {
        let db = try AppDatabase(inMemory: true)
        let clipRepo = ClipboardRepository(database: db)
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<120 {
            _ = try clipRepo.insertIfNew(ClipItem(id: nil, kind: .text, textContent: "row \(i) needle\(i)",
                                                  imagePath: nil, imageWidth: nil, imageHeight: nil,
                                                  previewText: "row \(i)", sourceApp: nil,
                                                  createdAt: base.addingTimeInterval(Double(i)),
                                                  pinned: false, contentHash: "h\(i)", lastUsedAt: nil))
        }
        let clipCache = ClipboardCache(repository: clipRepo)
        clipCache.loadAll()
        let snippetCache = SnippetCache(repository: SnippetRepository(database: db))
        snippetCache.loadAll()
        let vm = PopupViewModel(snippetCache: snippetCache, clipboardCache: clipCache)
        vm.reset()

        // Only the first page shows, but more remain.
        XCTAssertEqual(vm.clipResults.count, 50)
        XCTAssertTrue(vm.hasMoreClips)

        // Lazy-load the next page.
        vm.loadMoreClips()
        XCTAssertEqual(vm.clipResults.count, 100)

        // Search reaches an old item outside the initial window.
        vm.query = "needle0"
        XCTAssertEqual(vm.clipResults.count, 1)
        if case .clip(let item)? = vm.clipResults.first {
            XCTAssertEqual(item.textContent, "row 0 needle0")
        } else {
            XCTFail("Expected the matching clip")
        }
    }

    func testResetClearsQueryAndCollection() throws {
        let (vm, collection) = try makeViewModel()
        vm.enter(collection)
        vm.query = "x"
        vm.reset()
        XCTAssertEqual(vm.query, "")
        XCTAssertNil(vm.currentCollection)
        XCTAssertEqual(vm.selectedId, vm.results.first?.id)
    }
}
