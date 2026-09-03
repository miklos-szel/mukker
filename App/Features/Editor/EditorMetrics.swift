import CoreGraphics

/// Layout constants shared by the editor window sizing, the toolbar, and the
/// wheel-zoom hit test, so they can't silently drift apart.
enum EditorMetrics {
    /// Top row: window chrome — undo/redo, zoom, size readout, copy/save.
    static let chromeRowHeight: CGFloat = 30
    /// Second row: the tool palette and the contextual style controls.
    static let workRowHeight: CGFloat = 38

    /// Total toolbar height; also the wheel-zoom dead zone at the top of the
    /// window and part of the initial window-height calculation. Kept as the *sum*
    /// so splitting or resizing a row can't desync the dead zone from the bar.
    static let toolbarHeight: CGFloat = chromeRowHeight + workRowHeight

    /// Side length of a square toolbar icon tile.
    static let tileSize: CGFloat = 26
    /// Corner radius of a tile's hover/active background.
    static let tileCorner: CGFloat = 6
    /// Diameter of a color palette swatch.
    static let swatchSize: CGFloat = 16
    /// Width reserved at the leading edge for the window's traffic lights, which
    /// float over the toolbar (the window uses `.fullSizeContentView`).
    static let trafficLightGap: CGFloat = 68

    /// Minimum content width: what the *widest* toolbar state needs — row 2 with
    /// the text tool, which carries Copy/Save, the tool palette, the swatches, the
    /// size slider and the background toggle all at once. Measured, not guessed:
    /// below this the Copy/Save capsules and the trailing toggle start to clip.
    /// Moving Copy/Save down from row 1 cost ~150 pt here; the one-row toolbar
    /// still needed 1080.
    static let minWindowWidth: CGFloat = 1010
    /// Minimum content height: toolbar plus a usable canvas.
    static let minWindowHeight: CGFloat = 420
}
