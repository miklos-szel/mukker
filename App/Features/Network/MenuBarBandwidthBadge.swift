import AppKit
import CoreText

/// Draws the menu bar's bandwidth readout as an **inverted badge** — a filled
/// rounded box with `↓41 ↑25 Kbps` knocked out of it — in the same style as
/// `MenuBarDateIcon`, and composes it to the *left* of the date glyph.
///
/// Like the date glyph it is a **template** image: only the alpha channel
/// matters, the text is erased with `.destinationOut`, and macOS tints it for a
/// light/dark menu bar and inverts it while the menu is open.
///
/// Everything is laid out in fixed columns (see `numberColumn`), so the status
/// item never changes width — or shifts internally — as the traffic does.
enum MenuBarBandwidthBadge {
    /// Same 20 pt box as the date glyph, inside the full 22 pt menu bar.
    private static let height: CGFloat = 22
    private static let boxInset: CGFloat = 1
    private static let horizontalPadding: CGFloat = 5
    /// Space between the badge and the glyph after it — just enough to read
    /// as two elements.
    private static let gap: CGFloat = 3

    /// Condensed, like the date glyph's day number, so the figures run tall
    /// without making the badge wide.
    private static let numberFont = MenuBarDateIcon.digitFont(ofSize: 16)
    private static let unitFont = NSFont.systemFont(ofSize: 10, weight: .bold, width: MenuBarDateIcon.digitWidth)

    /// Fixed columns, measured once against the widest value each can hold:
    /// `↓888` and `↑888` are right-aligned in their own column and the unit is
    /// left-aligned after them, so neither the badge nor anything inside it
    /// moves when the figures or the unit change.
    private static let numberColumn: CGFloat = ceil(max(
        attributed("↓888", numberFont).size().width, attributed("↑888", numberFont).size().width))
    private static let unitColumn: CGFloat = ceil(["Kbps", "Mbps", "Gbps"]
        .map { attributed($0, unitFont).size().width }.max() ?? 0)
    private static let columnGap: CGFloat = 5
    private static let boxWidth: CGFloat =
        horizontalPadding * 2 + numberColumn * 2 + unitColumn + columnGap * 2

    /// The badge followed by `trailing` (the date glyph or the app glyph), as
    /// one template image.
    static func image(down: String, up: String, unit: String, trailing: NSImage?) -> NSImage {
        let trailingWidth = trailing.map { $0.size.width + gap } ?? 0
        let size = NSSize(width: boxWidth + trailingWidth, height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let box = NSRect(x: 0, y: boxInset, width: boxWidth, height: height - boxInset * 2)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()

            // Vertical placement from the digits' ink, as the date glyph does,
            // so the text doesn't sit high in the box.
            let ink = CTLineGetBoundsWithOptions(
                CTLineCreateWithAttributedString(attributed("↓888", numberFont)), .useGlyphPathBounds)
            let baseline = box.midY - ink.midY
            context.saveGState()
            context.setBlendMode(.destinationOut)
            var column = box.minX + horizontalPadding
            for value in [down, up] {
                let line = CTLineCreateWithAttributedString(attributed(value, numberFont))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                context.textPosition = CGPoint(x: column + numberColumn - width, y: baseline)
                CTLineDraw(line, context)
                column += numberColumn + columnGap
            }
            context.textPosition = CGPoint(x: column, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(attributed(unit, unitFont)), context)
            context.restoreGState()

            let x = boxWidth + gap
            trailing?.draw(in: NSRect(x: x, y: (height - (trailing?.size.height ?? 0)) / 2,
                                      width: trailing?.size.width ?? 0,
                                      height: trailing?.size.height ?? 0))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func attributed(_ string: String, _ font: NSFont) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font])
    }
}
