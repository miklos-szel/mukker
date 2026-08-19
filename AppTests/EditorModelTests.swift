import XCTest
import AppKit
@testable import Sniptory

final class EditorModelTests: XCTestCase {

    /// A solid-color base image at scale 1 (so logical points == pixels).
    private func solidImage(_ color: NSColor, size: Int = 100) -> CGImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    // MARK: - Tool shortcuts

    func testToolShortcutsRoundTrip() {
        for tool in Tool.allCases {
            XCTAssertEqual(Tool(shortcut: tool.shortcut), tool,
                           "\(tool) shortcut '\(tool.shortcut)' must map back to itself")
        }
    }

    func testToolShortcutsAreUnique() {
        let shortcuts = Tool.allCases.map(\.shortcut)
        XCTAssertEqual(Set(shortcuts).count, shortcuts.count, "tool shortcuts must be unique")
    }

    func testUnknownShortcutReturnsNil() {
        XCTAssertNil(Tool(shortcut: "z"))
    }

    // MARK: - Geometry

    func testBoundingBoxForLine() {
        var a = Annotation(kind: .line, style: AnnotationStyle())
        a.points = [CGPoint(x: 10, y: 80), CGPoint(x: 60, y: 20)]
        XCTAssertEqual(a.boundingBox, CGRect(x: 10, y: 20, width: 50, height: 60))
    }

    func testTranslateMovesRectAndPoints() {
        var a = Annotation(kind: .arrow, style: AnnotationStyle())
        a.rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        a.points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]
        a.translate(by: CGSize(width: 5, height: 7))
        XCTAssertEqual(a.rect.origin, CGPoint(x: 5, y: 7))
        XCTAssertEqual(a.points[1], CGPoint(x: 15, y: 17))
    }

    // MARK: - Drawing gestures

    @MainActor
    func testDragCreatesAndCommitsRectangle() {
        let vm = EditorViewModel(image: solidImage(.white), sourceScale: 1.0)
        vm.activeTool = .rectangle
        vm.dragChanged(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 40, y: 30))
        XCTAssertNotNil(vm.draft)
        XCTAssertEqual(vm.draft?.rect, CGRect(x: 10, y: 10, width: 30, height: 20))

        vm.dragEnded(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 40, y: 30))
        XCTAssertNil(vm.draft)
        XCTAssertEqual(vm.annotations.count, 1)
        XCTAssertEqual(vm.annotations.first?.rect, CGRect(x: 10, y: 10, width: 30, height: 20))
        XCTAssertEqual(vm.selectedID, vm.annotations.first?.id)
    }

    // MARK: - Esc key behavior

    @MainActor
    func testEscapeCancelsPendingCropFirst() {
        let vm = EditorViewModel(image: solidImage(.white), sourceScale: 1.0)
        vm.cropRect = CGRect(x: 0, y: 0, width: 10, height: 10)
        // Even with an annotation selected and the setting on, a pending crop wins.
        vm.dragChanged(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 40, y: 30))
        vm.dragEnded(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 40, y: 30))
        XCTAssertEqual(vm.escapeAction(escCopiesAndCloses: true), .cancelCrop)
    }

    @MainActor
    func testEscapeDeselectsWhenAnnotationSelected() {
        let vm = EditorViewModel(image: solidImage(.white), sourceScale: 1.0)
        vm.activeTool = .rectangle
        vm.dragChanged(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 40, y: 30))
        vm.dragEnded(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 40, y: 30))
        XCTAssertNotNil(vm.selectedID)
        // A selection takes priority over copy-and-close, even when the setting is on.
        XCTAssertEqual(vm.escapeAction(escCopiesAndCloses: true), .deselect)
    }

    @MainActor
    func testEscapeCopiesAndClosesWhenIdleAndEnabled() {
        let vm = EditorViewModel(image: solidImage(.white), sourceScale: 1.0)
        XCTAssertNil(vm.selectedID)
        XCTAssertNil(vm.cropRect)
        XCTAssertEqual(vm.escapeAction(escCopiesAndCloses: true), .copyAndClose)
    }

    @MainActor
    func testEscapeIsNoOpWhenIdleAndDisabled() {
        let vm = EditorViewModel(image: solidImage(.white), sourceScale: 1.0)
        // Setting off: idle Esc falls back to deselect (a no-op), never copy-and-close.
        XCTAssertEqual(vm.escapeAction(escCopiesAndCloses: false), .deselect)
    }

    @MainActor
    func testTinyDragIsDiscarded() {
        let vm = EditorViewModel(image: solidImage(.white), sourceScale: 1.0)
        vm.activeTool = .ellipse
        vm.dragChanged(start: CGPoint(x: 20, y: 20), current: CGPoint(x: 21, y: 21))
        vm.dragEnded(start: CGPoint(x: 20, y: 20), current: CGPoint(x: 21, y: 21))
        XCTAssertTrue(vm.annotations.isEmpty)
    }

    @MainActor
    func testCounterClickPlacesAndIncrements() {
        let vm = EditorViewModel(image: solidImage(.white), sourceScale: 1.0)
        vm.activeTool = .counter
        // A click (start == current) still places a fixed-size badge.
        vm.dragChanged(start: CGPoint(x: 50, y: 50), current: CGPoint(x: 50, y: 50))
        vm.dragEnded(start: CGPoint(x: 50, y: 50), current: CGPoint(x: 50, y: 50))
        XCTAssertEqual(vm.annotations.count, 1)
        XCTAssertEqual(vm.annotations[0].number, 1)

        vm.dragChanged(start: CGPoint(x: 90, y: 90), current: CGPoint(x: 90, y: 90))
        vm.dragEnded(start: CGPoint(x: 90, y: 90), current: CGPoint(x: 90, y: 90))
        XCTAssertEqual(vm.annotations.count, 2)
        XCTAssertEqual(vm.annotations[1].number, 2)
    }

    @MainActor
    func testFreehandAccumulatesPoints() {
        let vm = EditorViewModel(image: solidImage(.white), sourceScale: 1.0)
        vm.activeTool = .freehand
        vm.dragChanged(start: CGPoint(x: 0, y: 0), current: CGPoint(x: 0, y: 0))
        vm.dragChanged(start: CGPoint(x: 0, y: 0), current: CGPoint(x: 5, y: 5))
        vm.dragChanged(start: CGPoint(x: 0, y: 0), current: CGPoint(x: 10, y: 8))
        vm.dragEnded(start: CGPoint(x: 0, y: 0), current: CGPoint(x: 10, y: 8))
        XCTAssertEqual(vm.annotations.count, 1)
        XCTAssertGreaterThanOrEqual(vm.annotations[0].points.count, 3)
    }

    // MARK: - Selection / move / delete

    @MainActor
    func testSelectAndMove() {
        let vm = EditorViewModel(image: solidImage(.white), sourceScale: 1.0)
        vm.annotations = [Annotation(kind: .rectangle,
                                     rect: CGRect(x: 20, y: 20, width: 40, height: 40),
                                     style: AnnotationStyle())]
        vm.activeTool = .select
        vm.dragChanged(start: CGPoint(x: 30, y: 30), current: CGPoint(x: 50, y: 45))
        vm.dragEnded(start: CGPoint(x: 30, y: 30), current: CGPoint(x: 50, y: 45))
        XCTAssertEqual(vm.selectedID, vm.annotations.first?.id)
        XCTAssertEqual(vm.annotations[0].rect, CGRect(x: 40, y: 35, width: 40, height: 40))
    }

    @MainActor
    func testClickEmptyAreaDeselects() {
        let vm = EditorViewModel(image: solidImage(.white), sourceScale: 1.0)
        vm.annotations = [Annotation(kind: .rectangle,
                                     rect: CGRect(x: 20, y: 20, width: 10, height: 10),
                                     style: AnnotationStyle())]
        vm.selectedID = vm.annotations[0].id
        vm.activeTool = .select
        vm.dragChanged(start: CGPoint(x: 200, y: 200), current: CGPoint(x: 200, y: 200))
        vm.dragEnded(start: CGPoint(x: 200, y: 200), current: CGPoint(x: 200, y: 200))
        XCTAssertNil(vm.selectedID)
    }

    @MainActor
    func testDeleteSelected() {
        let vm = EditorViewModel(image: solidImage(.white), sourceScale: 1.0)
        vm.annotations = [Annotation(kind: .arrow,
                                     points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)],
                                     style: AnnotationStyle())]
        vm.selectedID = vm.annotations[0].id
        vm.deleteSelected()
        XCTAssertTrue(vm.annotations.isEmpty)
        XCTAssertNil(vm.selectedID)
    }

    @MainActor
    func testSetColorAppliesToSelection() {
        let vm = EditorViewModel(image: solidImage(.white), sourceScale: 1.0)
        vm.annotations = [Annotation(kind: .rectangle,
                                     rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                     style: AnnotationStyle())]
        vm.selectedID = vm.annotations[0].id
        vm.setColor(.blue)
        XCTAssertEqual(vm.annotations[0].style.color, .blue)
    }

    // MARK: - Blur / pixelate

    func testPixellatePreservesDimensions() throws {
        let base = solidImage(.white, size: 128)
        let pixelated = try XCTUnwrap(ImageEffects.pixellate(base))
        XCTAssertEqual(pixelated.width, 128)
        XCTAssertEqual(pixelated.height, 128)
    }

    @MainActor
    func testPixelatedBaseIsCachedAndInvalidatedByCrop() {
        let vm = EditorViewModel(image: solidImage(.white, size: 100), sourceScale: 1.0)
        let first = vm.pixelatedBase()
        XCTAssertTrue(first === vm.pixelatedBase(), "pixelated base should be cached")

        vm.cropRect = CGRect(x: 0, y: 0, width: 60, height: 60)
        vm.applyCrop()
        XCTAssertFalse(first === vm.pixelatedBase(), "crop must invalidate the pixelated cache")
    }

    @MainActor
    func testFlattenWithBlurKeepsResolution() {
        let vm = EditorViewModel(image: solidImage(.white, size: 100), sourceScale: 1.0)
        vm.annotations = [Annotation(kind: .blur,
                                     rect: CGRect(x: 10, y: 10, width: 40, height: 40),
                                     style: AnnotationStyle())]
        let out = vm.flatten()
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(out.height, 100)
    }

    // MARK: - Crop

    @MainActor
    func testApplyCropResizesImageAndReanchorsAnnotations() {
        // 100px image at scale 1 → 100pt logical.
        let vm = EditorViewModel(image: solidImage(.white, size: 100), sourceScale: 1.0)
        vm.annotations = [Annotation(kind: .rectangle,
                                     rect: CGRect(x: 30, y: 30, width: 10, height: 10),
                                     style: AnnotationStyle())]
        vm.activeTool = .crop
        vm.dragChanged(start: CGPoint(x: 20, y: 20), current: CGPoint(x: 80, y: 70))
        vm.dragEnded(start: CGPoint(x: 20, y: 20), current: CGPoint(x: 80, y: 70))
        XCTAssertEqual(vm.cropRect, CGRect(x: 20, y: 20, width: 60, height: 50))

        vm.applyCrop()
        XCTAssertNil(vm.cropRect)
        XCTAssertEqual(vm.baseImage.width, 60)
        XCTAssertEqual(vm.baseImage.height, 50)
        // The annotation shifts by the crop origin: (30,30) → (10,10).
        XCTAssertEqual(vm.annotations[0].rect.origin, CGPoint(x: 10, y: 10))
        XCTAssertEqual(vm.activeTool, .select)
    }

    @MainActor
    func testSwitchingToolClearsPendingCrop() {
        let vm = EditorViewModel(image: solidImage(.white), sourceScale: 1.0)
        vm.activeTool = .crop
        vm.dragChanged(start: CGPoint(x: 0, y: 0), current: CGPoint(x: 50, y: 50))
        XCTAssertNotNil(vm.cropRect)
        vm.activeTool = .arrow
        XCTAssertNil(vm.cropRect)
    }

    // MARK: - Flatten / export

    @MainActor
    func testFlattenWithNoAnnotationsReturnsBase() {
        let base = solidImage(.white)
        let vm = EditorViewModel(image: base, sourceScale: 1.0)
        let out = vm.flatten()
        XCTAssertEqual(out.width, base.width)
        XCTAssertEqual(out.height, base.height)
    }

    @MainActor
    func testFlattenCompositesAnnotation() throws {
        let base = solidImage(.white)
        let vm = EditorViewModel(image: base, sourceScale: 1.0)
        var style = AnnotationStyle()
        style.color = .red
        style.fillOpacity = 1.0
        // A filled highlight covering the whole image.
        vm.annotations = [Annotation(kind: .highlight,
                                     rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                     style: style)]
        let out = vm.flatten()
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(out.height, 100)

        let bitmap = try XCTUnwrap(NSBitmapImageRep(cgImage: out))
        let center = try XCTUnwrap(bitmap.colorAt(x: 50, y: 50)?.usingColorSpace(.sRGB))
        // The white base should now read predominantly red where the fill landed.
        XCTAssertGreaterThan(center.redComponent, 0.5)
        XCTAssertLessThan(center.blueComponent, 0.5)
    }

    @MainActor
    func testFlattenScalesToSourceResolution() {
        let base = solidImage(.white, size: 100)   // 100px at scale 2 → 50pt logical
        let vm = EditorViewModel(image: base, sourceScale: 2.0)
        vm.annotations = [Annotation(kind: .rectangle,
                                     rect: CGRect(x: 5, y: 5, width: 20, height: 20),
                                     style: AnnotationStyle())]
        let out = vm.flatten()
        // Output must be back at the original pixel resolution.
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(out.height, 100)
    }

    // MARK: - Canvas bounds: draft-stable layout + ratio-preserving extension

    /// Regression: starting a draw outside the image must not shift the layout
    /// geometry mid-gesture. `layoutBounds` (committed only) stays the image rect
    /// while the draft grows `contentBounds`.
    @MainActor
    func testLayoutBoundsIgnoreInProgressDraft() {
        let vm = EditorViewModel(image: solidImage(.white, size: 100), sourceScale: 1.0)
        vm.activeTool = .arrow
        vm.dragChanged(start: CGPoint(x: -30, y: -30), current: CGPoint(x: -10, y: -10))
        XCTAssertNotNil(vm.draft)
        XCTAssertEqual(vm.layoutBounds, CGRect(x: 0, y: 0, width: 100, height: 100),
                       "layout must stay put while a draft is being drawn outside")
        XCTAssertLessThan(vm.contentBounds.minX, 0,
                          "content (display) bounds should include the negative-space draft")

        vm.dragEnded(start: CGPoint(x: -30, y: -30), current: CGPoint(x: -10, y: -10))
        XCTAssertEqual(vm.annotations.count, 1)
        XCTAssertEqual(vm.annotations[0].points,
                       [CGPoint(x: -30, y: -30), CGPoint(x: -10, y: -10)])
    }

    @MainActor
    func testCanvasBoundsUnchangedWhenNothingOverflows() {
        let vm = EditorViewModel(image: solidImage(.white, size: 100), sourceScale: 1.0)
        vm.annotations = [Annotation(kind: .rectangle,
                                     rect: CGRect(x: 10, y: 10, width: 20, height: 20),
                                     style: AnnotationStyle())]
        XCTAssertEqual(vm.canvasBounds(for: vm.annotations),
                       CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    /// Drawing outside the capture extends the canvas back to the original
    /// aspect ratio (square here), containing the image.
    @MainActor
    func testCanvasBoundsKeepsOriginalAspectRatio() {
        let vm = EditorViewModel(image: solidImage(.white, size: 100), sourceScale: 1.0)
        vm.annotations = [Annotation(kind: .rectangle,
                                     rect: CGRect(x: 120, y: 20, width: 40, height: 40),
                                     style: AnnotationStyle())]
        let bounds = vm.canvasBounds(for: vm.annotations)
        XCTAssertEqual(bounds.width, bounds.height, accuracy: 0.01,
                       "square capture must stay square as the canvas extends")
        XCTAssertTrue(bounds.contains(CGRect(x: 0, y: 0, width: 100, height: 100)),
                      "extended bounds must still contain the original image")
    }

    // MARK: - Moving the captured image with the pointer tool

    @MainActor
    func testPointerDragMovesCapturedImage() {
        let vm = EditorViewModel(image: solidImage(.white, size: 100), sourceScale: 1.0)
        vm.activeTool = .select
        // Drag from empty space over the image (no annotations) → move the image.
        vm.dragChanged(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 30, y: 25))
        vm.dragEnded(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 30, y: 25))
        XCTAssertEqual(vm.imageOrigin, CGPoint(x: 20, y: 15))
        XCTAssertNil(vm.selectedID)

        vm.undo()
        XCTAssertEqual(vm.imageOrigin, .zero, "undo must restore the image position")
    }

    @MainActor
    func testCropAfterMoveReanchorsAndResetsOrigin() {
        let vm = EditorViewModel(image: solidImage(.white, size: 100), sourceScale: 1.0)
        vm.imageOrigin = CGPoint(x: 20, y: 0)        // image now spans (20,0)…(120,100)
        vm.activeTool = .crop
        vm.dragChanged(start: CGPoint(x: 30, y: 10), current: CGPoint(x: 90, y: 60))
        vm.dragEnded(start: CGPoint(x: 30, y: 10), current: CGPoint(x: 90, y: 60))
        XCTAssertEqual(vm.cropRect, CGRect(x: 30, y: 10, width: 60, height: 50))

        vm.applyCrop()
        XCTAssertEqual(vm.baseImage.width, 60)
        XCTAssertEqual(vm.baseImage.height, 50)
        XCTAssertEqual(vm.imageOrigin, .zero)
    }

    // MARK: - Fit / center

    @MainActor
    func testFitAndCenterUsesViewportFitZoom() {
        let vm = EditorViewModel(image: solidImage(.white, size: 100), sourceScale: 1.0)
        vm.zoom = 3.0
        vm.viewportSize = CGSize(width: 200, height: 200)
        vm.fitAndCenter()
        XCTAssertEqual(vm.zoom, vm.fitZoom(in: CGSize(width: 200, height: 200)))
        XCTAssertLessThanOrEqual(vm.zoom, 1.0, "fit never magnifies past 100%")
    }

    /// The fit zoom reserves `canvasPadding` points of margin on every side, so the
    /// scaled capture leaves room for the transparent surround in the viewport.
    @MainActor
    func testFitZoomReservesCanvasPadding() {
        // 400px image at scale 1 → 400pt logical, larger than the viewport.
        let vm = EditorViewModel(image: solidImage(.white, size: 400), sourceScale: 1.0,
                                 canvasPadding: 50)
        let viewport = CGSize(width: 200, height: 200)
        let zoom = vm.fitZoom(in: viewport)
        XCTAssertLessThanOrEqual(zoom, 1.0, "fit never magnifies past 100%")
        // Image + 50pt padding each side must fit within the viewport.
        let padded = (vm.logicalSize.width + 50 * 2) * zoom
        XCTAssertLessThanOrEqual(padded, viewport.width + 0.001,
                                 "padded capture must fit inside the viewport")
        // More padding than zero must zoom out further (smaller zoom).
        let noPad = EditorViewModel(image: solidImage(.white, size: 400), sourceScale: 1.0,
                                    canvasPadding: 0)
        XCTAssertLessThan(zoom, noPad.fitZoom(in: viewport),
                          "padding must reserve margin, shrinking the fit zoom")
    }

    // MARK: - Text background

    func testTextBackgroundOnByDefault() {
        XCTAssertTrue(AnnotationStyle().textBackground)
    }

    @MainActor
    func testToggleTextBackgroundAppliesToSelection() {
        let vm = EditorViewModel(image: solidImage(.white, size: 100), sourceScale: 1.0)
        XCTAssertTrue(vm.style.textBackground)
        vm.annotations = [Annotation(kind: .text,
                                     rect: CGRect(x: 10, y: 10, width: 80, height: 30),
                                     style: vm.style)]
        vm.selectedID = vm.annotations[0].id
        vm.toggleTextBackground()
        XCTAssertFalse(vm.style.textBackground)
        XCTAssertFalse(vm.annotations[0].style.textBackground)
    }
}
