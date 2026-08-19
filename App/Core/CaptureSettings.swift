import AppKit
import Combine

/// Output image format for saved screenshots.
enum SaveFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var label: String { self == .png ? "PNG" : "JPEG" }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

/// What happens immediately after a capture finishes.
enum AfterCapture: String, CaseIterable, Identifiable {
    case show, copy, save
    var id: String { rawValue }
    var label: String {
        switch self {
        case .show: return "Show"
        case .copy: return "Copy"
        case .save: return "Save"
        }
    }
}

/// Screen-capture and annotation-editor preferences, backed by `UserDefaults`;
/// published properties persist on change. Global capture shortcuts live in
/// `ShortcutSettings` (shared with the popup hotkey) and the login item lives in
/// `LoginItemService`.
@MainActor
final class CaptureSettings: ObservableObject {
    static let shared = CaptureSettings()

    private let defaults: UserDefaults

    @Published var saveDirectory: URL { didSet { defaults.set(saveDirectory.path, forKey: K.saveDir) } }
    @Published var saveFormat: SaveFormat { didSet { defaults.set(saveFormat.rawValue, forKey: K.format) } }
    @Published var downscaleRetina: Bool { didSet { defaults.set(downscaleRetina, forKey: K.downscale) } }
    @Published var afterCapture: AfterCapture { didSet { defaults.set(afterCapture.rawValue, forKey: K.after) } }
    /// Show the zoom/loupe magnifier while dragging a selection. Off by default.
    @Published var showMagnifier: Bool { didSet { defaults.set(showMagnifier, forKey: K.showMag) } }

    /// Close the editor window automatically after copying / saving. Both on by default.
    @Published var closeAfterCopy: Bool { didSet { defaults.set(closeAfterCopy, forKey: K.closeCopy) } }
    @Published var closeAfterSave: Bool { didSet { defaults.set(closeAfterSave, forKey: K.closeSave) } }

    /// When the editor has nothing selected and no pending crop, Esc copies the capture to
    /// the clipboard and closes the window (regardless of `closeAfterCopy`). Off by default.
    @Published var escCopiesAndCloses: Bool { didSet { defaults.set(escCopiesAndCloses, forKey: K.escCopyClose) } }

    /// Default annotation color (and text-background pill color), as an index into
    /// `AnnotationStyle.palette`. Defaults to red. The default text *foreground*
    /// color and default text size live alongside it.
    @Published var defaultColorIndex: Int { didSet { defaults.set(defaultColorIndex, forKey: K.defColor) } }
    @Published var defaultTextColorIndex: Int { didSet { defaults.set(defaultTextColorIndex, forKey: K.defTextColor) } }
    @Published var defaultTextSize: Double { didSet { defaults.set(defaultTextSize, forKey: K.defTextSize) } }
    @Published var defaultLineWidth: Double { didSet { defaults.set(defaultLineWidth, forKey: K.defLineWidth) } }

    /// Transparent margin (logical points) reserved around the capture when the
    /// editor opens, so it presents as a small canvas floating in the checkerboard
    /// surround. On-screen only — never part of the exported image.
    @Published var canvasPadding: Double { didSet { defaults.set(canvasPadding, forKey: K.canvasPadding) } }

    /// Whether debug-only menu items (e.g. "Open Sample Editor") are shown.
    @Published var enableDebugMenu: Bool { didSet { defaults.set(enableDebugMenu, forKey: K.debugMenu) } }

    /// Scrolling-capture limits. `scrollMaxHeight` caps the stitched image; speed
    /// (0…1) maps to the settle delay between scroll steps.
    @Published var scrollMaxHeight: Int { didSet { defaults.set(scrollMaxHeight, forKey: K.scrollMax) } }
    @Published var scrollSpeed: Double { didSet { defaults.set(scrollSpeed, forKey: K.scrollSpeed) } }

    /// Seconds to wait after each scroll step for the content to settle/render.
    var scrollSettleDelay: TimeInterval { 0.30 - 0.22 * scrollSpeed }

    /// Editor tool-key overrides, keyed by `Tool.rawValue` → single character.
    /// Empty means "use the built-in default"; resolved in the Editor layer
    /// (Core can't reference the `Tool` type). See `EditorShortcuts`.
    @Published var toolShortcuts: [String: String] { didSet { defaults.set(toolShortcuts, forKey: K.toolKeys) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saveDirectory = defaults.string(forKey: K.saveDir).map { URL(fileURLWithPath: $0) }
            ?? AppPaths.defaultSaveDirectory
        saveFormat = SaveFormat(rawValue: defaults.string(forKey: K.format) ?? "") ?? .png
        downscaleRetina = defaults.bool(forKey: K.downscale)
        afterCapture = AfterCapture(rawValue: defaults.string(forKey: K.after) ?? "") ?? .show
        showMagnifier = defaults.bool(forKey: K.showMag)
        closeAfterCopy = defaults.object(forKey: K.closeCopy) as? Bool ?? true
        closeAfterSave = defaults.object(forKey: K.closeSave) as? Bool ?? true
        escCopiesAndCloses = defaults.object(forKey: K.escCopyClose) as? Bool ?? false
        defaultColorIndex = defaults.object(forKey: K.defColor) as? Int ?? 0          // red
        defaultTextColorIndex = defaults.object(forKey: K.defTextColor) as? Int ?? 7  // white
        defaultTextSize = defaults.object(forKey: K.defTextSize) as? Double ?? 14
        defaultLineWidth = defaults.object(forKey: K.defLineWidth) as? Double ?? 2
        canvasPadding = defaults.object(forKey: K.canvasPadding) as? Double ?? 24
        enableDebugMenu = defaults.bool(forKey: K.debugMenu)
        toolShortcuts = defaults.dictionary(forKey: K.toolKeys) as? [String: String] ?? [:]
        scrollMaxHeight = defaults.object(forKey: K.scrollMax) as? Int ?? 20_000
        scrollSpeed = defaults.object(forKey: K.scrollSpeed) as? Double ?? 0.6
    }

    private enum K {
        static let saveDir = "saveDirectory"
        static let format = "saveFormat"
        static let downscale = "downscaleRetina"
        static let after = "afterCapture"
        static let showMag = "showMagnifierDuringCapture"
        static let closeCopy = "closeAfterCopy"
        static let closeSave = "closeAfterSave"
        static let escCopyClose = "escCopiesAndCloses"
        static let defColor = "defaultColorIndex"
        static let defTextColor = "defaultTextColorIndex"
        static let defTextSize = "defaultTextSize"
        static let defLineWidth = "defaultLineWidth"
        static let canvasPadding = "canvasPadding"
        static let debugMenu = "enableDebugMenu"
        static let toolKeys = "toolShortcuts"
        static let scrollMax = "scrollMaxHeight"
        static let scrollSpeed = "scrollSpeed"
    }
}
