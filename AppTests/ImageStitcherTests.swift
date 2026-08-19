import XCTest
import AppKit
@testable import Sniptory

final class ImageStitcherTests: XCTestCase {

    /// A tall image whose every row has a distinct brightness, so row signatures
    /// are unique and overlap matching is unambiguous.
    private func rowGradient(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            let v = CGFloat(y) / CGFloat(height - 1)   // 0…1 per row
            ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return ctx.makeImage()!
    }

    private func frame(_ source: CGImage, topOffset: Int, height: Int) -> CGImage {
        source.cropping(to: CGRect(x: 0, y: topOffset, width: source.width, height: height))!
    }

    func testScrollDistanceRecoversStep() {
        let source = rowGradient(width: 8, height: 120)
        let frameHeight = 40
        let step = 12

        let base = ImageStitcher.rowSignatures(frame(source, topOffset: 0, height: frameHeight))
        let next = ImageStitcher.rowSignatures(frame(source, topOffset: step, height: frameHeight))

        let distance = ImageStitcher.scrollDistance(base: base, next: next, maxStep: frameHeight)
        XCTAssertEqual(distance, step, accuracy: 1)
    }

    func testIdenticalFramesReportNoProgress() {
        let source = rowGradient(width: 8, height: 120)
        let f = ImageStitcher.rowSignatures(frame(source, topOffset: 20, height: 40))
        XCTAssertEqual(ImageStitcher.scrollDistance(base: f, next: f, maxStep: 40), 0)
    }

    func testRowSignaturesAreDistinctPerRow() {
        // A per-row gradient must yield one strictly-monotonic signature per row.
        let source = rowGradient(width: 8, height: 50)
        let sigs = ImageStitcher.rowSignatures(source)
        XCTAssertEqual(sigs.count, 50)
        XCTAssertEqual(Set(sigs.map { ($0 * 100).rounded() }).count, sigs.count,
                       "each row should have a distinct signature")
    }

    func testVerticalStackSumsHeights() {
        let source = rowGradient(width: 8, height: 120)
        let strips = [
            frame(source, topOffset: 0, height: 40),
            frame(source, topOffset: 40, height: 12),
            frame(source, topOffset: 52, height: 8)
        ]
        let stacked = ImageStitcher.verticalStack(strips, width: 8)
        XCTAssertEqual(stacked?.width, 8)
        XCTAssertEqual(stacked?.height, 60)
    }
}
