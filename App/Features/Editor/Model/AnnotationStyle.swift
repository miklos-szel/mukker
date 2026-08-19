import SwiftUI

/// Visual style shared by annotations. New annotations adopt the editor's
/// current style; per-kind fields (cornerRadius, fontSize) are ignored by kinds
/// that don't use them.
struct AnnotationStyle: Equatable {
    // Defaults match the seeded values in `CaptureSettings` (Settings → Tools),
    // so contexts that bypass settings (tests, previews) see what users see.
    var color: Color = .red
    var lineWidth: CGFloat = 2
    var cornerRadius: CGFloat = 12
    var fontSize: CGFloat = 14
    /// Fill opacity for the highlight marker.
    var fillOpacity: Double = 0.35
    /// Whether a text annotation is drawn on a filled background pill (text in
    /// `textColor` on the `color` pill) rather than plain `textColor` text.
    var textBackground: Bool = true
    /// Foreground color of text annotations (the pill fill uses `color`).
    var textColor: Color = .white

    /// A small set of preset colors shown in the toolbar palette.
    static let palette: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .black, .white
    ]

    /// Display names for `palette`, index-aligned — tooltips and VoiceOver need
    /// more than an unlabeled colored circle to tell the swatches apart.
    static let paletteNames: [String] = [
        "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Black", "White"
    ]
}
