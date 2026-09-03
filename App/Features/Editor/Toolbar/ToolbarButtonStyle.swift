import SwiftUI

/// Press style for the editor toolbar: a springy scale-down plus a highlight flash
/// behind the label, so a click is clearly visible (the system `.borderless`
/// pressed state is a barely perceptible dim). The plain form is shape-agnostic —
/// labels range from 26×26 icon tiles to the custom floppy-disk glyph; the
/// `prominent` form is its own filled capsule.
///
/// This handles *press* only. Hover and the active/selected state live in
/// `ToolTile` and `ColorSwatch`, so the three stack into a rest → hover → press
/// ramp rather than fighting each other.
struct ToolbarButtonStyle: ButtonStyle {
    /// Prominent buttons (Copy/Save) are filled accent capsules with white
    /// content, so the primary actions read as primary instead of as another
    /// faintly tinted tile — a 15%-opacity wash over the `.bar` material came out
    /// as a muddy grey rectangle rather than a button.
    var prominent = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        if prominent {
            prominentBody(configuration)
        } else {
            plainBody(configuration)
        }
    }

    private func prominentBody(_ configuration: Configuration) -> some View {
        configuration.label
            // White on accent, glyphs included — the floppy fills with
            // `Color.primary`, which would go black on a blue capsule.
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .brightness(configuration.isPressed ? -0.12 : 0)
                    // A hairline lighter rim keeps the capsule from dissolving
                    // into a dark toolbar.
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                    )
                    .shadow(color: Color.accentColor.opacity(configuration.isPressed ? 0.15 : 0.3),
                            radius: configuration.isPressed ? 1 : 3, y: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.spring(response: 0.2, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }

    private func plainBody(_ configuration: Configuration) -> some View {
        configuration.label
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: EditorMetrics.tileCorner)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.18) : .clear)
            )
            .padding(-2)
            // Gentle: the previous 0.78/0.85 scale read as a jitter rather than a press.
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            // Custom styles lose the system's automatic disabled dimming
            // (Undo/Redo are routinely disabled), so reapply it here.
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.spring(response: 0.2, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ToolbarButtonStyle {
    static var toolbar: ToolbarButtonStyle { ToolbarButtonStyle() }
    static var toolbarProminent: ToolbarButtonStyle { ToolbarButtonStyle(prominent: true) }
}
