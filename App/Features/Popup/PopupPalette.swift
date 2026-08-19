import SwiftUI

/// Resolves the popup's region backgrounds (panel, search row, list, preview),
/// honoring the user's custom background color from `ClipboardSettings`. When the
/// custom color is off, each region falls back to its appearance-adaptive
/// `PopupTheme` color — so the whole box, not just the gaps between regions,
/// follows the chosen color.
@MainActor
enum PopupPalette {
    private static var custom: Color? {
        let settings = ClipboardSettings.shared
        return settings.popupCustomBackgroundEnabled ? settings.popupBackgroundColor : nil
    }

    static var panel: Color { custom ?? PopupTheme.panelBackground }
    static var list: Color { custom ?? PopupTheme.listBackground }
    static var preview: Color { custom ?? PopupTheme.previewBackground }
    static var search: Color { custom ?? PopupTheme.searchBackground }
}
