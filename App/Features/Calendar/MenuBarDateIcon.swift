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
    /// The full height of the 22 pt menu bar; the page sits centred in it at
    /// whatever height the user picked.
    static let slotHeight: CGFloat = 22
    static let defaultHeight = CalendarSettings.defaultGlyphHeight

    /// Keeps the knocked-out number clear of the square's rounded corners.
    private static let margin: CGFloat = 1.5

    /// A page slightly taller than it is wide (19 × 20 at the default size), so
    /// the day number reads large. Shares its height with
    /// `MenuBarBandwidthBadge`'s box so the two always line up.
    nonisolated static func page(height: CGFloat) -> NSRect {
        let range = CalendarSettings.glyphHeightRange
        let height = min(max(height, CGFloat(range.lowerBound)), CGFloat(range.upperBound))
        return NSRect(x: 0.5, y: (slotHeight - height) / 2, width: (height * 0.95).rounded(), height: height)
    }

    nonisolated static func image(day: Int, height: CGFloat = CGFloat(defaultHeight)) -> NSImage {
        let page = page(height: height)
        let font = numberFont(for: page)
        let size = NSSize(width: page.width + 1, height: slotHeight)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            NSColor.black.setFill()
            NSBezierPath(roundedRect: page, xRadius: cornerRadius(page.height),
                         yRadius: cornerRadius(page.height)).fill()

            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: String(day), attributes: [.font: font]))
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

    /// 4 pt at the default size, scaled with it.
    nonisolated static func cornerRadius(_ height: CGFloat) -> CGFloat { (height / 5).rounded() }

    /// One size for every day of the month: the largest whose **two** digits' ink
    /// fits the page. The page's width is what limits the size, which is why the
    /// digits are slightly condensed — they can run taller in the same width.
    /// Sizing per-day would make single digits noticeably bigger and resize the
    /// glyph on the 10th; measuring ink rather than advance width is what lets
    /// it run as large as the reference glyphs beside it. Recomputed per call —
    /// the caller caches the finished image per day and size.
    private nonisolated static func numberFont(for page: NSRect) -> NSFont {
        let available = page.insetBy(dx: margin, dy: margin)
        var size: CGFloat = 20
        while size > 6 {
            let font = digitFont(ofSize: size)
            let ink = inkBounds(of: "00", font: font)
            if ink.width <= available.width && ink.height <= available.height { return font }
            size -= 0.25
        }
        return digitFont(ofSize: size)
    }

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
