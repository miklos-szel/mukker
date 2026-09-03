import SwiftUI

/// One selectable color circle. Shared by the editor toolbar and Settings →
/// Capture, which previously carried near-identical hand-rolled copies that drifted
/// apart (different sizes, different ring opacities).
///
/// Every swatch keeps a hairline under the selection ring, because `.white` on the
/// toolbar's `.bar` material was previously all but invisible in light mode: a
/// 1 pt `Color.primary.opacity(0.25)` border was its only edge.
struct ColorSwatch: View {
    let color: Color
    /// Display name — tooltip and VoiceOver label. An unlabeled circle tells a
    /// screen reader nothing.
    let name: String
    let isSelected: Bool
    var size: CGFloat = EditorMetrics.swatchSize
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                // Hairline first, so light swatches always have an edge.
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                .overlay(
                    Circle().strokeBorder(Color.accentColor,
                                          lineWidth: isSelected ? 2 : (hovering ? 1.5 : 0))
                )
                // Selection halo: reads at a glance without thickening the ring
                // enough to swallow the color itself.
                .overlay(
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(isSelected ? 0.35 : 0),
                                      lineWidth: 2)
                        .padding(-2.5)
                )
                .scaleEffect(hovering && !isSelected ? 1.15 : 1)
                .padding(2)   // room for the halo and the hover growth
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

/// The full `AnnotationStyle.palette` as a row of `ColorSwatch`es, selected by
/// index. Both the editor toolbar and the Capture settings pane render this.
struct ColorSwatchRow: View {
    /// Index of the selected color in `AnnotationStyle.palette`, or nil when the
    /// current color isn't one of the presets.
    let selectedIndex: Int?
    var size: CGFloat = EditorMetrics.swatchSize
    var spacing: CGFloat = 2
    let onSelect: (Int, Color) -> Void

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(AnnotationStyle.palette.enumerated()), id: \.offset) { index, color in
                ColorSwatch(color: color,
                            name: AnnotationStyle.paletteNames[index],
                            isSelected: selectedIndex == index,
                            size: size) { onSelect(index, color) }
            }
        }
    }
}
