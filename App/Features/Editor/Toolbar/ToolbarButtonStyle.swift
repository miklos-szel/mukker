import SwiftUI

/// Press style for the editor toolbar: a springy scale-down plus a soft highlight
/// flash behind the label, so a click is clearly visible (the system `.borderless`
/// pressed state is a barely perceptible dim). Shape-agnostic — labels range from
/// 26×26 icon tiles to 16 pt color circles and the custom floppy-disk glyph.
struct ToolbarButtonStyle: ButtonStyle {
    /// Prominent buttons (Copy/Save) get a deeper press and an accent-tinted
    /// flash so the click registers even when the window closes right after.
    var prominent = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(prominent ? 4 : 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed
                          ? (prominent
                             ? Color.accentColor.opacity(0.4)
                             : Color.primary.opacity(0.15))
                          : .clear)
            )
            .padding(prominent ? -4 : -2)
            .scaleEffect(configuration.isPressed ? (prominent ? 0.78 : 0.85) : 1)
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
