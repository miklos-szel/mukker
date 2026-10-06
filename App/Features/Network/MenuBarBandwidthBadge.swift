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
    /// Space between the badge and the glyph after it — just enough to read
    /// as two elements.
    private static let gap: CGFloat = 3

    /// Every measurement the badge needs at one box height. All of it scales
    /// with the box (the defaults below are the 20 pt sizes), so the
    /// user-chosen menu bar size grows the badge and the date glyph together.
    private struct Layout {
        let box: CGFloat
        let numberFont: NSFont
        let unitFont: NSFont
        let padding: CGFloat
        let columnGap: CGFloat
        /// Fixed columns, measured against the widest value each can hold:
        /// `↓888` and `↑888` are right-aligned in their own column and the unit
        /// is left-aligned after them, so neither the badge nor anything inside
        /// it moves when the figures or the unit change.
        let numberColumn: CGFloat
        let unitColumn: CGFloat

        var width: CGFloat { padding * 2 + numberColumn * 2 + unitColumn + columnGap * 2 }

        init(box: CGFloat) {
            let scale = box / 20
            self.box = box
            // Slightly condensed, like the date glyph's day number, so the
            // figures run tall without making the badge wide.
            let numbers = MenuBarDateIcon.digitFont(ofSize: 16 * scale)
            let units = NSFont.systemFont(ofSize: 10 * scale, weight: .bold, width: MenuBarDateIcon.digitWidth)
            numberFont = numbers
            unitFont = units
            padding = (5 * scale).rounded()
            columnGap = (5 * scale).rounded()
            numberColumn = ceil(max(attributed("↓888", numbers).size().width,
                                    attributed("↑888", numbers).size().width))
            unitColumn = ceil(["Kbps", "Mbps", "Gbps"]
                .map { attributed($0, units).size().width }.max() ?? 0)
        }
    }

    /// The badge followed by `trailing` (the date glyph or the app glyph), as
    /// one template image. `height` is the box height — the same value the date
    /// glyph's page uses.
    static func image(down: String, up: String, unit: String, trailing: NSImage?,
                      height: CGFloat = CGFloat(MenuBarDateIcon.defaultHeight)) -> NSImage {
        let slot = MenuBarDateIcon.slotHeight
        let page = MenuBarDateIcon.page(height: height)
        let layout = Layout(box: page.height)
        let trailingWidth = trailing.map { $0.size.width + gap } ?? 0
        let size = NSSize(width: layout.width + trailingWidth, height: slot)

        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let box = NSRect(x: 0, y: page.minY, width: layout.width, height: page.height)
            let radius = MenuBarDateIcon.cornerRadius(page.height)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()

            // Vertical placement from the digits' ink, as the date glyph does,
            // so the text doesn't sit high in the box.
            let ink = CTLineGetBoundsWithOptions(
                CTLineCreateWithAttributedString(attributed("↓888", layout.numberFont)), .useGlyphPathBounds)
            let baseline = box.midY - ink.midY
            context.saveGState()
            context.setBlendMode(.destinationOut)
            var column = box.minX + layout.padding
            for value in [down, up] {
                let line = CTLineCreateWithAttributedString(attributed(value, layout.numberFont))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                context.textPosition = CGPoint(x: column + layout.numberColumn - width, y: baseline)
                CTLineDraw(line, context)
                column += layout.numberColumn + layout.columnGap
            }
            context.textPosition = CGPoint(x: column, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(attributed(unit, layout.unitFont)), context)
            context.restoreGState()

            if let trailing {
                trailing.draw(in: NSRect(x: layout.width + gap, y: (slot - trailing.size.height) / 2,
                                         width: trailing.size.width, height: trailing.size.height))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func attributed(_ string: String, _ font: NSFont) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font])
    }
}
