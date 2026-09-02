import AppKit

/// Draws the menu bar's calendar-page glyph with today's date inside it.
///
/// While Keep Awake is on the page is drawn **filled**, with the day number
/// knocked out of it. An 18 pt glyph has no room for a corner badge beside a
/// two-digit number, and the awake state cannot be a colour: the result is a
/// **template** image, so macOS tints it for the light/dark menu bar and inverts
/// it while the menu is open — only the alpha channel matters, which is why
/// every stroke below is plain black.
enum MenuBarDateIcon {
    /// Matches the 18 pt menu-bar glyphs the app already ships.
    static let size = NSSize(width: 18, height: 18)

    nonisolated static func image(day: Int, awake: Bool = false) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            let page = NSRect(x: 1.5, y: 1.25, width: 15, height: 15.5)
            let barHeight: CGFloat = 3
            let body = NSBezierPath(roundedRect: page, xRadius: 2.5, yRadius: 2.5)
            NSColor.black.setFill()

            if awake {
                body.fill()
            } else {
                let outline = NSBezierPath(roundedRect: page.insetBy(dx: 0.75, dy: 0.75),
                                           xRadius: 2.5, yRadius: 2.5)
                outline.lineWidth = 1.25
                NSColor.black.setStroke()
                outline.stroke()

                // The binding bar across the top, clipped to the rounded outline
                // so its corners follow the page.
                NSGraphicsContext.saveGraphicsState()
                body.addClip()
                NSBezierPath(rect: NSRect(x: page.minX, y: page.maxY - barHeight,
                                          width: page.width, height: barHeight)).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            // The day number, centred in what is left of the page — drawn solid
            // on an outlined page, knocked back out of a filled one.
            let text = String(day) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: day > 9 ? 8.5 : 9.5,
                                                        weight: .semibold),
                .foregroundColor: NSColor.black
            ]
            let textSize = text.size(withAttributes: attributes)
            let interior = NSRect(x: page.minX, y: page.minY,
                                  width: page.width, height: page.height - barHeight)
            let origin = NSPoint(x: interior.midX - textSize.width / 2,
                                 y: interior.midY - textSize.height / 2 - (awake ? 1.25 : 0.25))
            NSGraphicsContext.current?.compositingOperation = awake ? .destinationOut : .sourceOver
            text.draw(at: origin, withAttributes: attributes)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        return image
    }
}
