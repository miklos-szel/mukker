import XCTest
import AppKit
@testable import AppCore

/// Covers `WindowTiler`'s pure geometry. The AX half needs a real window and a
/// real permission grant, so it is verified by hand; everything that can be
/// gotten wrong arithmetically lives in these statics.
final class WindowTilerTests: XCTestCase {

    /// A `visibleFrame` with a deliberately non-zero origin — a second display,
    /// or the primary one minus the Dock — so nothing can quietly assume `.zero`.
    private let visible = CGRect(x: 100, y: 50, width: 1440, height: 800)

    // MARK: - Halves

    func testHalvesSplitTheVisibleFrame() {
        XCTAssertEqual(WindowTiler.rect(for: .left, in: visible, gap: 0),
                       CGRect(x: 100, y: 50, width: 720, height: 800))
        XCTAssertEqual(WindowTiler.rect(for: .right, in: visible, gap: 0),
                       CGRect(x: 820, y: 50, width: 720, height: 800))
        XCTAssertEqual(WindowTiler.rect(for: .top, in: visible, gap: 0),
                       CGRect(x: 100, y: 450, width: 1440, height: 400))
        XCTAssertEqual(WindowTiler.rect(for: .bottom, in: visible, gap: 0),
                       CGRect(x: 100, y: 50, width: 1440, height: 400))
    }

    /// Cocoa is bottom-left-origin, so the top half is the one with the larger Y.
    func testTopIsTheHigherHalfInCocoaCoordinates() {
        let top = WindowTiler.rect(for: .top, in: visible, gap: 0)
        let bottom = WindowTiler.rect(for: .bottom, in: visible, gap: 0)
        XCTAssertGreaterThan(top.minY, bottom.minY)
        XCTAssertEqual(top.maxY, visible.maxY)
        XCTAssertEqual(bottom.minY, visible.minY)
    }

    func testOpposingHalvesTileTheFrameExactly() {
        for (a, b) in [(TileSlot.left, TileSlot.right), (.top, .bottom)] {
            let first = WindowTiler.rect(for: a, in: visible, gap: 0)
            let second = WindowTiler.rect(for: b, in: visible, gap: 0)
            XCTAssertFalse(first.intersects(second), "\(a) and \(b) overlap")
            XCTAssertEqual(first.union(second), visible, "\(a) + \(b) don't cover the frame")
        }
    }

    // MARK: - Gap

    func testGapInsetsEveryEdge() {
        let left = WindowTiler.rect(for: .left, in: visible, gap: 10)
        XCTAssertEqual(left, CGRect(x: 110, y: 60, width: 700, height: 780))
        // Two windows side by side therefore end up 2 × gap apart.
        let right = WindowTiler.rect(for: .right, in: visible, gap: 10)
        XCTAssertEqual(right.minX - left.maxX, 20)
    }

    func testAbsurdGapClampsInsteadOfInverting() {
        let rect = WindowTiler.rect(for: .top, in: visible, gap: 5_000)
        XCTAssertEqual(rect.width, 0)
        XCTAssertEqual(rect.height, 0)
    }

    func testNegativeGapIsIgnored() {
        XCTAssertEqual(WindowTiler.rect(for: .left, in: visible, gap: -20),
                       WindowTiler.rect(for: .left, in: visible, gap: 0))
    }

    // MARK: - Coordinate flip

    /// AX is top-left-origin with Y growing downwards, anchored at the top-left
    /// of the primary display; Cocoa is bottom-left-origin.
    func testCocoaToAXFlipsTheOrigin() {
        // Bottom-left quarter-height strip of a 900 pt primary display.
        XCTAssertEqual(WindowTiler.axRect(fromCocoa: CGRect(x: 0, y: 0, width: 720, height: 450),
                                          primaryHeight: 900),
                       CGRect(x: 0, y: 450, width: 720, height: 450))
        // A window flush with the top of the primary display sits at AX y = 0.
        XCTAssertEqual(WindowTiler.axRect(fromCocoa: CGRect(x: 0, y: 450, width: 720, height: 450),
                                          primaryHeight: 900),
                       CGRect(x: 0, y: 0, width: 720, height: 450))
    }

    func testAXAndCocoaRoundTrip() {
        let original = CGRect(x: 137, y: 42, width: 613, height: 271)
        let ax = WindowTiler.axRect(fromCocoa: original, primaryHeight: 1080)
        XCTAssertEqual(WindowTiler.cocoaRect(fromAX: ax, primaryHeight: 1080), original)
    }

    /// A secondary display above the primary has negative AX Y — the flip must
    /// not clamp it.
    func testScreenAboveThePrimaryGivesNegativeAXY() {
        let ax = WindowTiler.axRect(fromCocoa: CGRect(x: 0, y: 900, width: 800, height: 600),
                                    primaryHeight: 900)
        XCTAssertEqual(ax.minY, -600)
    }
}
