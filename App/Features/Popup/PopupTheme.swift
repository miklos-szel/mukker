import AppKit
import SwiftUI

/// Centralized color palette for the popup. Light mode keeps the original
/// design — light-gray panel, dark row text, vivid purple selection — and
/// every color now has a dark-mode counterpart via dynamic NSColors, so the
/// popup follows the system appearance.
enum PopupTheme {
    // MARK: SwiftUI colors

    static let panelBackground = color(light: rgb(0.92, 0.92, 0.93), dark: rgb(0.16, 0.16, 0.17))
    static let listBackground = color(light: rgb(0.93, 0.93, 0.94), dark: rgb(0.17, 0.17, 0.18))
    static let rowSelected = color(light: rgb(0.50, 0.25, 0.90), dark: rgb(0.55, 0.30, 0.95))
    static let rowSelectedBottom = color(light: rgb(0.44, 0.18, 0.84), dark: rgb(0.48, 0.22, 0.88))
    static let primaryText = color(light: white(0.13), dark: white(0.92))
    static let secondaryText = color(light: white(0.45), dark: white(0.62))
    static let tertiaryText = color(light: white(0.55), dark: white(0.50))
    static let accent = color(light: rgb(0.50, 0.25, 0.90), dark: rgb(0.68, 0.50, 1.0))
    static let divider = color(light: NSColor.black.withAlphaComponent(0.10),
                               dark: NSColor.white.withAlphaComponent(0.12))
    static let breadcrumbBackground = color(light: NSColor.black.withAlphaComponent(0.04),
                                            dark: NSColor.white.withAlphaComponent(0.05))
    static let searchBackground = color(light: white(0.88), dark: white(0.12))

    /// Muted gray used for the preview footer (counts + date).
    static let footerText = color(light: white(0.50), dark: white(0.58))

    static let previewBackground = color(light: rgb(0.90, 0.90, 0.91), dark: rgb(0.14, 0.14, 0.15))
    static let previewText = color(light: white(0.40), dark: white(0.65))

    // MARK: AppKit colors (for the AppKit-backed search field and RTF preview)

    static let searchTextColor = dynamic(light: white(0.13), dark: white(0.92))
    static let searchPlaceholderColor = dynamic(light: NSColor(calibratedWhite: 0.13, alpha: 0.35),
                                                dark: NSColor(calibratedWhite: 0.92, alpha: 0.35))
    /// Opaque light backdrop the rich-text preview always renders on — rich
    /// clips carry their own (typically dark) text colors, so they stay on a
    /// light card in both appearances (see RichTextView).
    static let richTextBackdrop = rgb(0.90, 0.90, 0.91)

    // MARK: Helpers

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static func color(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: dynamic(light: light, dark: dark))
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func white(_ w: CGFloat) -> NSColor {
        NSColor(calibratedWhite: w, alpha: 1)
    }
}
