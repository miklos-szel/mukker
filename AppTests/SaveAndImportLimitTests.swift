import XCTest
import ZIPFoundation
@testable import AppCore

final class SaveAndImportLimitTests: XCTestCase {

    // MARK: - Screenshot file names

    func testUniqueFileNameReturnsNameWhenFree() {
        XCTAssertEqual(ImageExporter.uniqueFileName("Shot.png") { _ in false }, "Shot.png")
    }

    func testUniqueFileNameAppendsCounterBeforeExtension() {
        let taken: Set<String> = ["scr_2026-05-29_09-41-12.png", "scr_2026-05-29_09-41-12_2.png"]
        XCTAssertEqual(ImageExporter.uniqueFileName("scr_2026-05-29_09-41-12.png") { taken.contains($0) },
                       "scr_2026-05-29_09-41-12_3.png")
        XCTAssertEqual(ImageExporter.uniqueFileName("noext") { $0 == "noext" }, "noext_2")
    }

    func testSuggestedFileNameIsScrDateTimeWithoutSpaces() {
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 5, 29)
        (components.hour, components.minute, components.second) = (9, 41, 12)
        let date = Calendar(identifier: .gregorian).date(from: components)!
        XCTAssertEqual(AppPaths.suggestedFileName(date: date), "scr_2026-05-29_09-41-12.png")
        XCTAssertEqual(AppPaths.suggestedFileName(date: date, fileExtension: "jpg"), "scr_2026-05-29_09-41-12.jpg")
        XCTAssertFalse(AppPaths.suggestedFileName().contains(" "))
    }

    // MARK: - Import limits

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mukker-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeArchive(entries: Int, bytesEach: Int) throws -> URL {
        let url = try makeTempDir().appendingPathComponent("bundle.alfredsnippets")
        let archive = try Archive(url: url, accessMode: .create)
        let payload = Data(repeating: 0x41, count: bytesEach)
        for i in 0..<entries {
            try archive.addEntry(with: "s\(i).json", type: .file, uncompressedSize: Int64(payload.count),
                                 compressionMethod: .deflate) { position, size in
                payload.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return url
    }

    func testBundleImporterRejectsArchiveOverSizeLimit() throws {
        let url = try makeArchive(entries: 2, bytesEach: 600)
        var importer = SnippetBundleImporter()
        importer.maxUncompressedBytes = 1_000
        XCTAssertThrowsError(try importer.parse(url: url)) { error in
            guard case SnippetBundleImporter.ImportError.archiveTooLarge = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testBundleImporterRejectsArchiveOverEntryLimit() throws {
        let url = try makeArchive(entries: 4, bytesEach: 1)
        var importer = SnippetBundleImporter()
        importer.maxEntries = 3
        XCTAssertThrowsError(try importer.parse(url: url)) { error in
            guard case SnippetBundleImporter.ImportError.archiveTooLarge = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testMukkerImporterRejectsFileOverSizeLimit() throws {
        let url = try makeTempDir().appendingPathComponent("export.json")
        try Data(repeating: 0x20, count: 2_048).write(to: url)
        var importer = MukkerImporter(repository: SnippetRepository(database: try AppDatabase(inMemory: true)))
        importer.maxFileBytes = 1_024
        XCTAssertThrowsError(try importer.importFile(at: url)) { error in
            guard case MukkerImporter.ImportError.fileTooLarge = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }
}
