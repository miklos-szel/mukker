import AppKit

/// Draws the menu bar's date glyph: a filled rounded square with today's day
/// number knocked out of it.
///
/// The result is a **template** image, so macOS tints it for the light/dark menu
/// bar and inverts it while the menu is open — only the alpha channel matters,
/// which is why everything below is plain black and the number is erased with
/// `.destinationOut` rather than drawn in a second colour.
///
/// The glyph does **not** signal Keep Awake. It is the date, and there is no room
/// beside a two-digit number for a badge; the awake state is reported by the
/// menu's Keep Awake line instead. (With the date switched off the status item
/// falls back to the app glyph, which does still swap.)
enum MenuBarDateIcon {
    /// Matches the 18 pt menu-bar glyphs the app already ships.
    static let size = NSSize(width: 18, height: 18)

    /// Sized off the system's own boxed menu-bar glyphs (the input-source badge),
    /// which fill 16 pt of the 18 pt slot — a smaller square reads as an odd
    /// runt beside them.
    private static let page = NSRect(x: 0.5, y: 1, width: 17, height: 16)
    /// Keeps the knocked-out number clear of the square's rounded corners.
    private static let margin: CGFloat = 1.5

    nonisolated static func image(day: Int) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: page, xRadius: 4, yRadius: 4).fill()

            let text = String(day) as NSString
            let font = numberFont
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            // Centred on the digits' cap height, not on the line box: the box
            // carries ascender and descender room the digits don't fill, and
            // centring by it leaves the number sitting visibly high.
            let baseline = page.midY - font.capHeight / 2
            let origin = NSPoint(
                x: page.midX - text.size(withAttributes: attributes).width / 2,
                y: baseline + font.descender)

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            text.draw(at: origin, withAttributes: attributes)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        return image
    }

    /// One size for every day of the month: the largest that fits **two**
    /// monospaced digits inside the square. Sizing per-day would make single
    /// digits noticeably bigger and resize the glyph on the 10th.
    private static let numberFont: NSFont = {
        let available = page.insetBy(dx: margin, dy: margin)
        var size: CGFloat = 12
        while size > 6 {
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
            let width = ("00" as NSString).size(withAttributes: [.font: font]).width
            if width <= available.width && font.capHeight <= available.height { return font }
            size -= 0.25
        }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
    }()
}
