import AppKit

/// Captures content taller than the screen by auto-scrolling the region under the
/// selection and stitching the frames. There is no native scrolling-capture API,
/// so this synthesizes scroll-wheel events (needs Accessibility) and matches frame
/// overlap with `ImageStitcher`.
@MainActor
final class ScrollingCaptureService {
    static let shared = ScrollingCaptureService()

    /// Delivers the stitched image and its source scale (pixels per point).
    var onComplete: ((CGImage, CGFloat) -> Void)?

    private let overlay = SelectionOverlayController()
    private var isCapturing = false

    /// Hard caps so a runaway page can't loop forever.
    private let maxIterations = 400

    func capture() {
        guard !isCapturing else { return }
        guard PermissionsService.shared.ensureScreenRecording() else { return }
        guard PermissionsService.shared.ensureAccessibility(
            reason: "Scrolling capture needs Accessibility access to scroll the target automatically."
        ) else { return }

        isCapturing = true
        Task {
            do {
                let captures = try await ScreenCaptureService.shared.captureAllDisplays()
                overlay.present(captures: captures) { [weak self] result in
                    guard let self else { return }
                    guard let (capture, pixelRect) = result, pixelRect.width > 8, pixelRect.height > 8 else {
                        self.isCapturing = false
                        return
                    }
                    Task { await self.run(capture: capture, pixelRect: pixelRect) }
                }
            } catch {
                Log.capture.error("scrolling capture setup failed: \(error.localizedDescription, privacy: .public)")
                isCapturing = false
            }
        }
    }

    private func run(capture: DisplayCapture, pixelRect: CGRect) async {
        defer { isCapturing = false }
        let settings = CaptureSettings.shared
        let scale = capture.scale

        // Region in display points (top-left origin) for the capturer's sourceRect.
        let regionPoints = CGRect(x: pixelRect.minX / scale, y: pixelRect.minY / scale,
                                  width: pixelRect.width / scale, height: pixelRect.height / scale)

        // Seed the first strip from the overlay-free image frozen at selection
        // time. Capturing a live frame for the top band would catch the selection
        // overlay before it finishes tearing down, leaving it dimmed/blurry.
        guard let firstFrame = capture.image.cropping(to: pixelRect) else {
            Log.capture.error("scrolling capture: could not crop the initial frame")
            return
        }
        let pixelWidth = firstFrame.width
        let pixelHeight = firstFrame.height

        // Move the cursor over the region so scroll events land on the right view;
        // remember where it was so it can be put back when the capture finishes.
        let savedCursor = CGEvent(source: nil)?.location
        let bounds = CGDisplayBounds(capture.displayID)
        let cursor = CGPoint(x: bounds.minX + regionPoints.midX, y: bounds.minY + regionPoints.midY)
        CGWarpMouseCursorPosition(cursor)
        defer { if let savedCursor { CGWarpMouseCursorPosition(savedCursor) } }

        guard let capturer = try? await ScreenCaptureService.shared.regionCapturer(displayID: capture.displayID) else {
            Log.capture.error("scrolling capture: could not build region capturer")
            return
        }

        let stepPoints = max(40, regionPoints.height * 0.85)
        var strips: [CGImage] = [firstFrame]
        var previousSignatures = ImageStitcher.rowSignatures(firstFrame)
        var totalHeight = pixelHeight
        var staleCount = 0

        for _ in 0..<maxIterations {
            postScroll(byPoints: -Int(stepPoints))
            try? await Task.sleep(for: .seconds(settings.scrollSettleDelay))

            guard let frame = try? await capturer.capture(
                sourceRect: regionPoints,
                pixelSize: CGSize(width: pixelWidth, height: pixelHeight)) else { break }

            let signatures = ImageStitcher.rowSignatures(frame)
            let advanced = ImageStitcher.scrollDistance(base: previousSignatures,
                                                        next: signatures, maxStep: pixelHeight)
            if advanced <= 1 {
                staleCount += 1
                if staleCount >= 2 { break }   // bottom reached
                continue
            }
            staleCount = 0
            let stripRect = CGRect(x: 0, y: pixelHeight - advanced, width: pixelWidth, height: advanced)
            if let strip = frame.cropping(to: stripRect) {
                strips.append(strip)
                totalHeight += advanced
            }
            previousSignatures = signatures

            if totalHeight >= settings.scrollMaxHeight { break }
        }

        guard let stitched = ImageStitcher.verticalStack(strips, width: pixelWidth) else {
            Log.capture.error("scrolling capture: nothing to stitch")
            return
        }
        Log.capture.info("scrolling capture stitched \(stitched.width)×\(stitched.height)px from \(strips.count) frames")
        onComplete?(stitched, scale)
    }

    /// Post a vertical scroll-wheel event at the current cursor. Negative scrolls
    /// the content downward (revealing lower content).
    private func postScroll(byPoints points: Int) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 1, wheel1: Int32(points), wheel2: 0, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }
}
