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
    /// The full height of the 22 pt menu bar, so the page can be as tall as the
    /// bar allows.
    static let size = NSSize(width: 20, height: 22)

    /// Taller than it is wide: 20 of the bar's 22 points, so the day number
    /// reads large. Shares its height with `MenuBarBandwidthBadge`'s box.
    private static let page = NSRect(x: 0.5, y: 1, width: 19, height: 20)
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
    /// fits the page. The digits are SF **condensed**: the page's width is what
    /// limits the size, and narrower digits can run taller in the same width. Sizing per-day would make single digits noticeably bigger
    /// and resize the glyph on the 10th; measuring ink rather than advance width
    /// is what lets it run as large as the reference glyphs beside it.
    private static let numberFont: NSFont = {
        let available = page.insetBy(dx: margin, dy: margin)
        var size: CGFloat = 18
        while size > 6 {
            let font = digitFont(ofSize: size)
            let ink = inkBounds(of: "00", font: font)
            if ink.width <= available.width && ink.height <= available.height { return font }
            size -= 0.25
        }
        return digitFont(ofSize: size)
    }()

    /// Bold, slightly condensed, tabular digits — shared with the bandwidth
    /// badge. Halfway between standard and `.condensed` (-0.2): fully condensed
    /// read as squeezed, standard width can't run as tall.
    static let digitWidth = NSFont.Width(rawValue: -0.1)

    nonisolated static func digitFont(ofSize size: CGFloat) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: .bold, width: digitWidth)
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
        ]]])
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    private nonisolated static func inkBounds(of text: String, font: NSFont) -> CGRect {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    }
}
