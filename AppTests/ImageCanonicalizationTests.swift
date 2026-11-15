import AppKit
import XCTest
@testable import AppCore

final class ImageCanonicalizationTests: XCTestCase {

    /// A small opaque RGBA bitmap, PNG- or TIFF-encoded.
    private func makeImageData(width: Int, height: Int, type: NSBitmapImageRep.FileType) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<height {
            for x in 0..<width {
                rep.setColor(NSColor(deviceRed: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height),
                                     blue: 0.5, alpha: 1), atX: x, y: y)
            }
        }
        return try XCTUnwrap(rep.representation(using: type, properties: [:]))
    }

    func testReturnsPNGWithPixelDimensions() throws {
        let data = try makeImageData(width: 7, height: 5, type: .png)
        let image = try XCTUnwrap(ClipboardMonitor.canonicalImage(from: data))
        XCTAssertEqual(image.width, 7)
        XCTAssertEqual(image.height, 5)
        XCTAssertEqual(Array(image.png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(image.hash, ContentHash.sha256Hex(image.png))
    }

    func testIdenticalInputGivesIdenticalHash() throws {
        let data = try makeImageData(width: 9, height: 4, type: .png)
        let a = try XCTUnwrap(ClipboardMonitor.canonicalImage(from: data))
        let b = try XCTUnwrap(ClipboardMonitor.canonicalImage(from: data))
        XCTAssertEqual(a, b)
    }

    /// Runs off the main thread in the app; the result must not depend on that.
    func testBackgroundQueueMatchesMainThread() throws {
        let data = try makeImageData(width: 6, height: 6, type: .tiff)
        let onMain = ClipboardMonitor.canonicalImage(from: data)
        var offMain: ClipboardMonitor.CanonicalImage?
        DispatchQueue(label: "test.canonical").sync { offMain = ClipboardMonitor.canonicalImage(from: data) }
        XCTAssertNotNil(onMain)
        XCTAssertEqual(onMain, offMain)
    }

    func testRejectsNonImageData() {
        XCTAssertNil(ClipboardMonitor.canonicalImage(from: Data("not an image".utf8)))
    }

    func testRowThumbnailBoundGivesShortEdgeFortyPixels() {
        XCTAssertEqual(ClipThumbnailCache.rowThumbnailMaxPixelSize(for: CGSize(width: 1600, height: 900)),
                       40 * 1600 / 900, accuracy: 0.001)
        XCTAssertEqual(ClipThumbnailCache.rowThumbnailMaxPixelSize(for: CGSize(width: 100, height: 100)), 40)
        // Panoramas are capped.
        XCTAssertEqual(ClipThumbnailCache.rowThumbnailMaxPixelSize(for: CGSize(width: 10_000, height: 100)), 400)
    }
}
