import SwiftUI

/// A square icon tile for the editor toolbar, with three visually distinct states
/// so a click can never look like nothing happened: rest, hover, and *on* (the
/// active tool / engaged toggle). The press feedback comes from `ToolbarButtonStyle`
/// on top of this — together they give a rest → hover → press → on ramp.
///
/// Replaces the three hand-rolled copies of the old
/// `RoundedRectangle.fill(Color.accentColor.opacity(0.25))` active background,
/// whose 25% tint was too faint to spot at a glance.
struct ToolTile<Content: View>: View {
    var isOn: Bool = false
    /// Tooltip text; also the VoiceOver label when `content` is a bare icon.
    var help: String
    /// Tile side length. Defaults to the toolbar's standard tile.
    var size: CGFloat = EditorMetrics.tileSize
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var hovering = false
    /// A disabled tile (Undo/Redo routinely are) must not light up under the
    /// pointer — that would advertise an action that won't happen.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: size, height: size)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: EditorMetrics.tileCorner)
                        .fill(fill)
                )
        }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .onHover { hovering = $0 && isEnabled }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }

    /// On wins over hover: an engaged tile stays unmistakably accent-filled, just
    /// slightly brighter under the pointer.
    private var fill: Color {
        if isOn { return Color.accentColor.opacity(hovering ? 0.85 : 1) }
        return hovering && isEnabled ? Color.primary.opacity(0.09) : .clear
    }
}

extension ToolTile where Content == Image {
    /// Convenience for the common case: an SF Symbol tile.
    init(systemImage: String, isOn: Bool = false, help: String,
         size: CGFloat = EditorMetrics.tileSize, action: @escaping () -> Void) {
        self.init(isOn: isOn, help: help, size: size, action: action) {
            Image(systemName: systemImage)
        }
    }
}
