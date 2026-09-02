import SwiftUI

/// Press style for the editor toolbar: a springy scale-down plus a highlight flash
/// behind the label, so a click is clearly visible (the system `.borderless`
/// pressed state is a barely perceptible dim). Shape-agnostic — labels range from
/// 26×26 icon tiles to the custom floppy-disk glyph.
///
/// This handles *press* only. Hover and the active/selected state live in
/// `ToolTile` and `ColorSwatch`, so the three stack into a rest → hover → press
/// ramp rather than fighting each other.
struct ToolbarButtonStyle: ButtonStyle {
    /// Prominent buttons (Copy/Save) carry a resting accent tint so the primary
    /// actions read as primary, and flash deeper on press so the click registers
    /// even when the window closes right after.
    var prominent = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(prominent ? 4 : 2)
            .background(
                RoundedRectangle(cornerRadius: EditorMetrics.tileCorner)
                    .fill(fill(pressed: configuration.isPressed))
            )
            .padding(prominent ? -4 : -2)
            // Gentle: the previous 0.78/0.85 scale read as a jitter rather than a press.
            .scaleEffect(configuration.isPressed ? (prominent ? 0.90 : 0.92) : 1)
            // Custom styles lose the system's automatic disabled dimming
            // (Undo/Redo are routinely disabled), so reapply it here.
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.spring(response: 0.2, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }

    private func fill(pressed: Bool) -> Color {
        if prominent {
            return Color.accentColor.opacity(pressed ? 0.45 : 0.15)
        }
        return pressed ? Color.primary.opacity(0.18) : .clear
    }
}

extension ButtonStyle where Self == ToolbarButtonStyle {
    static var toolbar: ToolbarButtonStyle { ToolbarButtonStyle() }
    static var toolbarProminent: ToolbarButtonStyle { ToolbarButtonStyle(prominent: true) }
}
