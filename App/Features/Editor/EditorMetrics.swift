import CoreGraphics

/// Layout constants shared by the editor window sizing, the toolbar, and the
/// wheel-zoom hit test, so they can't silently drift apart.
enum EditorMetrics {
    /// Height of the editor toolbar; also the wheel-zoom dead zone at the top
    /// of the window and part of the initial window-height calculation.
    static let toolbarHeight: CGFloat = 44
    /// Minimum content width that keeps the whole toolbar visible.
    static let minWindowWidth: CGFloat = 1080
    /// Minimum content height: toolbar plus a usable canvas.
    static let minWindowHeight: CGFloat = 420
}
