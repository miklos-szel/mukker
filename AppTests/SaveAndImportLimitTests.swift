import XCTest
import ZIPFoundation
@testable import AppCore

final class SaveAndImportLimitTests: XCTestCase {

    // MARK: - Screenshot file names

    func testUniqueFileNameReturnsNameWhenFree() {
        XCTAssertEqual(ImageExporter.uniqueFileName("Shot.png") { _ in false }, "Shot.png")
    }

    func testUniqueFileNameAppendsCounterBeforeExtension() {
        let taken: Set<String> = ["Shot at 09.41.12.png", "Shot at 09.41.12 2.png"]
        XCTAssertEqual(ImageExporter.uniqueFileName("Shot at 09.41.12.png") { taken.contains($0) },
                       "Shot at 09.41.12 3.png")
        XCTAssertEqual(ImageExporter.uniqueFileName("noext") { $0 == "noext" }, "noext 2")
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
