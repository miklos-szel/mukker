import AppKit
import SwiftUI

/// Hex (de)serialization for `Color`, used to persist user-selected popup colors
/// in `UserDefaults`. Always round-trips through the sRGB color space and encodes
/// alpha, so a stored color renders identically regardless of system appearance.
extension Color {
    /// `#RRGGBBAA` representation in the sRGB color space.
    var hexRGBA: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        let a = Int((ns.alphaComponent * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA` (the leading `#` is optional). Returns nil
    /// for malformed input so callers can fall back to a default.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }

        let r, g, b, a: Double
        switch s.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            return nil
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// True when the color is light enough that dark text reads better on it.
    /// Uses Rec. 601 luma over the sRGB components. Drives the popup's forced
    /// appearance so a custom background always contrasts with its text.
    var isLight: Bool {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let luma = 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
        return luma > 0.55
    }
}
