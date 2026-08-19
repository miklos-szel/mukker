import XCTest
@testable import Sniptory

final class ForeverHistoryArchiveTests: XCTestCase {

    private func tempDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fh-\(UUID().uuidString)", isDirectory: true)
        return dir.path
    }

    private func textItem(_ content: String, hash: String, at date: Date = Date()) -> ClipItem {
        ClipItem(id: nil, kind: .text, textContent: content, imagePath: nil,
                 imageWidth: nil, imageHeight: nil, previewText: String(content.prefix(20)),
                 sourceApp: nil, createdAt: date, pinned: false, contentHash: hash, lastUsedAt: nil)
    }

    func testWritesTextItemsWhenEnabled() throws {
        let dir = tempDir()
        let items = [textItem("hello", hash: "aaaa1111"), textItem("world", hash: "bbbb2222")]
        ForeverHistoryArchive.archive(items, enabled: true, directory: dir)

        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
        XCTAssertEqual(files.count, 2)
        let contents = try files.map { try String(contentsOfFile: dir + "/" + $0, encoding: .utf8) }.sorted()
        XCTAssertEqual(contents, ["hello", "world"])
    }

    func testDisabledWritesNothing() {
        let dir = tempDir()
        ForeverHistoryArchive.archive([textItem("x", hash: "c")], enabled: false, directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
    }

    func testNonTextIgnored() {
        let dir = tempDir()
        let img = ClipItem(id: nil, kind: .image, textContent: nil, imagePath: "/tmp/x.png",
                           imageWidth: 1, imageHeight: 1, previewText: nil, sourceApp: nil,
                           createdAt: Date(), pinned: false, contentHash: "img", lastUsedAt: nil)
        ForeverHistoryArchive.archive([img], enabled: true, directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
    }

    func testDedupeSameTimestampAndHash() throws {
        let dir = tempDir()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let item = textItem("dup", hash: "dddd4444", at: when)
        ForeverHistoryArchive.archive([item], enabled: true, directory: dir)
        ForeverHistoryArchive.archive([item], enabled: true, directory: dir)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
        XCTAssertEqual(files.count, 1)
    }
}
