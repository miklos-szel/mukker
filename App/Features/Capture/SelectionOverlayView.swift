import AppKit

/// Full-screen capture overlay for one display: shows the frozen screenshot,
/// dims everything outside the drag selection, and draws a crosshair, a live
/// size badge, and a magnifier loupe with a pixel-color readout.
final class SelectionOverlayView: NSView {
    let capture: DisplayCapture
    /// Whether to draw the magnifier loupe + color readout under the cursor.
    let showMagnifier: Bool
    private let nsImage: NSImage
    private let bitmap: NSBitmapImageRep?

    /// Selection in *image pixels* (top-left origin), or nil to cancel.
    var onComplete: ((CGRect?) -> Void)?

    private var dragStart: CGPoint?
    private var currentRect: CGRect = .zero
    private var mouseLocation: CGPoint = .zero
    private var isDragging = false

    private let dimColor = NSColor.black.withAlphaComponent(0.45)
    private let accent = NSColor.systemBlue
    private let loupeSizePts: CGFloat = 130
    private let loupeSamplePts: CGFloat = 26

    init(capture: DisplayCapture, showMagnifier: Bool = false) {
        self.capture = capture
        self.showMagnifier = showMagnifier
        self.nsImage = NSImage(cgImage: capture.image,
                               size: NSSize(width: capture.screen.frame.width,
                                            height: capture.screen.frame.height))
        self.bitmap = NSBitmapImageRep(cgImage: capture.image)
        super.init(frame: capture.screen.frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }        // top-left origin, matches image pixels
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        isDragging = true
        currentRect = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        guard let start = dragStart else { return }
        currentRect = rect(from: start, to: mouseLocation)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        guard let start = dragStart else { return }
        let r = rect(from: start, to: convert(event.locationInWindow, from: nil))
        dragStart = nil
        if r.width < 4 || r.height < 4 {
            onComplete?(nil)
        } else {
            onComplete?(pixelRect(from: r))
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onComplete?(nil) }   // Esc
        else { super.keyDown(with: event) }
    }

    // MARK: - Geometry

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
            .integral
            .intersection(bounds)
    }

    /// Convert a point-space rect (top-left origin) into image-pixel coordinates.
    private func pixelRect(from r: CGRect) -> CGRect {
        let s = capture.scale
        return CGRect(x: r.minX * s, y: r.minY * s,
                      width: r.width * s, height: r.height * s).integral
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Frozen screenshot at full brightness.
        nsImage.draw(in: bounds)

        // Dim everything, then punch the selection back to full brightness.
        dimColor.setFill()
        bounds.fill()
        if !currentRect.isEmpty {
            ctx.saveGState()
            ctx.clip(to: currentRect)
            nsImage.draw(in: bounds)
            ctx.restoreGState()

            accent.setStroke()
            let border = NSBezierPath(rect: currentRect)
            border.lineWidth = 1.5
            border.stroke()
            drawSizeBadge(for: currentRect)
        }

        if !isDragging || currentRect.isEmpty {
            drawCrosshair(at: mouseLocation)
        }
        if showMagnifier { drawLoupe(at: mouseLocation) }
    }

    private func drawCrosshair(at p: CGPoint) {
        guard bounds.contains(p) else { return }
        accent.withAlphaComponent(0.6).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: CGPoint(x: bounds.minX, y: p.y))
        path.line(to: CGPoint(x: bounds.maxX, y: p.y))
        path.move(to: CGPoint(x: p.x, y: bounds.minY))
        path.line(to: CGPoint(x: p.x, y: bounds.maxY))
        path.stroke()
    }

    private func drawSizeBadge(for r: CGRect) {
        let s = capture.scale
        let text = "\(Int(r.width * s)) × \(Int(r.height * s))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 6
        var origin = CGPoint(x: r.minX, y: r.minY - size.height - pad * 2 - 4)
        if origin.y < bounds.minY + 4 { origin.y = r.maxY + 4 }
        let box = CGRect(x: origin.x, y: origin.y,
                         width: size.width + pad * 2, height: size.height + pad * 2)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad), withAttributes: attrs)
    }

    private func drawLoupe(at p: CGPoint) {
        guard let cg = capture.image.cropping(to: loupeSampleRect(at: p)) else { return }

        // Position the loupe near the cursor, flipping to stay on-screen.
        var origin = CGPoint(x: p.x + 18, y: p.y + 18)
        if origin.x + loupeSizePts > bounds.maxX { origin.x = p.x - 18 - loupeSizePts }
        if origin.y + loupeSizePts + 22 > bounds.maxY { origin.y = p.y - 18 - loupeSizePts - 22 }
        let loupe = CGRect(x: origin.x, y: origin.y, width: loupeSizePts, height: loupeSizePts)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let clip = NSBezierPath(roundedRect: loupe, xRadius: 8, yRadius: 8)
        clip.addClip()
        ctx.interpolationQuality = .none
        NSImage(cgImage: cg, size: loupe.size).draw(in: loupe)
        ctx.restoreGState()

        // Center crosshair inside the loupe.
        accent.setStroke()
        let cx = loupe.midX, cy = loupe.midY
        let cross = NSBezierPath()
        cross.lineWidth = 1
        cross.move(to: CGPoint(x: loupe.minX, y: cy)); cross.line(to: CGPoint(x: loupe.maxX, y: cy))
        cross.move(to: CGPoint(x: cx, y: loupe.minY)); cross.line(to: CGPoint(x: cx, y: loupe.maxY))
        cross.stroke()
        let outline = NSBezierPath(roundedRect: loupe, xRadius: 8, yRadius: 8)
        outline.lineWidth = 1
        NSColor.white.withAlphaComponent(0.9).setStroke()
        outline.stroke()

        drawColorReadout(below: loupe, at: p)
    }

    private func loupeSampleRect(at p: CGPoint) -> CGRect {
        let s = capture.scale
        let half = loupeSamplePts * s / 2
        let cx = p.x * s, cy = p.y * s
        let full = CGRect(x: 0, y: 0, width: CGFloat(capture.image.width), height: CGFloat(capture.image.height))
        return CGRect(x: cx - half, y: cy - half, width: loupeSamplePts * s, height: loupeSamplePts * s)
            .intersection(full)
    }

    private func drawColorReadout(below loupe: CGRect, at p: CGPoint) {
        guard let bitmap, bounds.contains(p) else { return }
        let s = capture.scale
        let px = min(max(Int(p.x * s), 0), capture.image.width - 1)
        let py = min(max(Int(p.y * s), 0), capture.image.height - 1)
        guard let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return }
        let hex = String(format: "#%02X%02X%02X",
                         Int(color.redComponent * 255),
                         Int(color.greenComponent * 255),
                         Int(color.blueComponent * 255))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let box = CGRect(x: loupe.minX, y: loupe.maxY + 2, width: loupe.width, height: 18)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        let swatch = CGRect(x: box.minX + 5, y: box.midY - 5, width: 10, height: 10)
        color.setFill(); NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()
        (hex as NSString).draw(at: CGPoint(x: swatch.maxX + 5, y: box.minY + 3), withAttributes: attrs)
    }
}
