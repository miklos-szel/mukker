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

        let vm = PopupViewModel(snippetCache: snippetCache, clipboardCache: clipCache,
                                snippetRepository: snippetRepo)
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

    func testResetRebuildsResultsOnce() throws {
        let (vm, collection) = try makeViewModel()
        vm.enter(collection)
        vm.query = "x"
        var publishes = 0
        let sub = vm.$results.dropFirst().sink { _ in publishes += 1 }
        vm.reset()
        sub.cancel()
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(vm.query, "")
        XCTAssertNil(vm.currentCollection)
        XCTAssertEqual(vm.selectedId, vm.results.first?.id)
    }

    func testResetBumpsShowGeneration() throws {
        let (vm, _) = try makeViewModel()
        vm.reset()
        let generation = vm.showGeneration
        vm.reset()
        XCTAssertEqual(vm.showGeneration, generation &+ 1)
    }

    func testRefreshKeepingSelectionDoesNotScroll() throws {
        let (vm, _) = try makeViewModel()
        vm.reset()
        let tick = vm.scrollTick
        vm.refreshResults()
        XCTAssertEqual(vm.scrollTick, tick, "same row, same position: no scroll")
        vm.moveSelection(by: 1)
        XCTAssertNotEqual(vm.scrollTick, tick, "arrow movement scrolls")
        let afterMove = vm.scrollTick
        // A query that drops the selected row moves the selection → scroll.
        vm.query = "unrelated"
        XCTAssertNotEqual(vm.scrollTick, afterMove)
    }

    func testSelectedPreviewCarriesFullTextAndCounts() throws {
        let db = try AppDatabase(inMemory: true)
        let clipRepo = ClipboardRepository(database: db)
        let big = String(repeating: "héllo wörld ", count: 400)   // > 3 KB → stripped from the cache
        _ = try clipRepo.insertIfNew(ClipItem(id: nil, kind: .text, textContent: big,
                                              imagePath: nil, imageWidth: nil, imageHeight: nil,
                                              previewText: String(big.prefix(200)), sourceApp: nil,
                                              createdAt: Date(), pinned: false, contentHash: "big", lastUsedAt: nil))
        let clipCache = ClipboardCache(repository: clipRepo)
        clipCache.loadAll()
        XCTAssertNil(clipCache.items.first?.textContent)
        let vm = PopupViewModel(snippetCache: SnippetCache(repository: SnippetRepository(database: db)),
                                clipboardCache: clipCache)
        vm.reset()

        let preview = try XCTUnwrap(vm.selectedPreview)
        XCTAssertEqual(preview.text, big)
        XCTAssertEqual(preview.words, 800)
        XCTAssertEqual(preview.characters, 12 * 400)
        XCTAssertEqual(preview.bytes, big.utf8.count)
        XCTAssertEqual(preview.countsLine, "800 words; 4800 chars; \(big.utf8.count) bytes")
    }

    func testSelectedPreviewIsNilForCollections() throws {
        let (vm, _) = try makeViewModel()
        vm.reset()   // first row is the collection
        XCTAssertNil(vm.selectedPreview)
        vm.moveSelection(by: 1)   // first clip
        guard case .clip(let item)? = vm.selectedResult else { return XCTFail("Expected a clip row") }
        XCTAssertEqual(vm.selectedPreview?.text, item.textContent)
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

    // MARK: Add a clip to snippets

    private func firstTextClip(_ vm: PopupViewModel, matching text: String) throws -> ClipItem {
        vm.reset()
        let item = vm.clipResults.compactMap { result -> ClipItem? in
            if case .clip(let item) = result { return item } else { return nil }
        }.first { $0.textContent == text }
        return try XCTUnwrap(item)
    }

    func testAddClipWithCustomNameCreatesSnippetInCollection() throws {
        let (vm, collection) = try makeViewModel()
        let cid = try XCTUnwrap(collection.id)
        let item = try firstTextClip(vm, matching: "select from t")

        XCTAssertNoThrow(try vm.addClip(item, toCollectionId: cid, name: "  My query  "))

        vm.enter(collection)
        let names = vm.snippetResults.compactMap { r -> String? in
            if case .snippet(let s) = r { return s.name } else { return nil }
        }
        XCTAssertTrue(names.contains("My query"), "got \(names)")
        let added = vm.snippetResults.compactMap { r -> Snippet? in
            if case .snippet(let s) = r, s.name == "My query" { return s } else { return nil }
        }.first
        XCTAssertEqual(added?.content, "select from t")
        XCTAssertEqual(added?.collectionId, cid)
    }

    func testAddClipWithBlankNameFallsBackToSuggestedName() throws {
        let (vm, collection) = try makeViewModel()
        let cid = try XCTUnwrap(collection.id)
        let item = try firstTextClip(vm, matching: "unrelated")
        XCTAssertEqual(vm.suggestedSnippetName(for: item), "unrelated")

        try vm.addClip(item, toCollectionId: cid, name: "   ")

        vm.enter(collection)
        XCTAssertTrue(vm.snippetResults.contains {
            if case .snippet(let s) = $0 { return s.name == "unrelated" } else { return false }
        })
    }

    func testAddClipToNewCollectionCreatesBoth() throws {
        let (vm, _) = try makeViewModel()
        let item = try firstTextClip(vm, matching: "select from t")

        try vm.addClip(item, toNewCollection: " Queries ", snippetName: "Pick")

        vm.reset()
        let newCollection = vm.snippetResults.compactMap { r -> SnippetCollection? in
            if case .collection(let c) = r, c.name == "Queries" { return c } else { return nil }
        }.first
        let col = try XCTUnwrap(newCollection)
        vm.enter(col)
        XCTAssertEqual(vm.snippetResults.count, 1)
        if case .snippet(let s) = vm.snippetResults.first {
            XCTAssertEqual(s.name, "Pick")
            XCTAssertEqual(s.content, "select from t")
        } else {
            XCTFail("Expected the new snippet")
        }
    }

    func testAddClipToNewCollectionRejectsBlankCollectionName() throws {
        let (vm, _) = try makeViewModel()
        let item = try firstTextClip(vm, matching: "select from t")
        XCTAssertThrowsError(try vm.addClip(item, toNewCollection: "  ", snippetName: "Pick"))
        vm.reset()
        XCTAssertEqual(vm.snippetResults.count, 1, "no collection may be created")
    }
}
