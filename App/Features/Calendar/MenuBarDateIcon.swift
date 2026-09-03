import AppKit
import CoreText

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
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            NSColor.black.setFill()
            NSBezierPath(roundedRect: page, xRadius: 4, yRadius: 4).fill()

            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: String(day), attributes: [.font: numberFont]))
            // Centred on the digits' **ink**, not on their line box: the box carries
            // ascender, descender and leading the digits never fill, and centring on
            // it leaves the number sitting visibly high in the square.
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.saveGState()
            // The number is erased out of the square rather than drawn in a second
            // colour — the image is a template, so only its alpha means anything.
            context.setBlendMode(.destinationOut)
            context.textPosition = CGPoint(x: page.midX - ink.midX, y: page.midY - ink.midY)
            CTLineDraw(line, context)
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// One size for every day of the month: the largest whose **two** digits' ink
    /// fits the square. Sizing per-day would make single digits noticeably bigger
    /// and resize the glyph on the 10th; measuring ink rather than advance width
    /// is what lets it run as large as the reference glyphs beside it.
    private static let numberFont: NSFont = {
        let available = page.insetBy(dx: margin, dy: margin)
        var size: CGFloat = 13
        while size > 6 {
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
            let ink = inkBounds(of: "00", font: font)
            if ink.width <= available.width && ink.height <= available.height { return font }
            size -= 0.25
        }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
    }()

    private nonisolated static func inkBounds(of text: String, font: NSFont) -> CGRect {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    }
}
