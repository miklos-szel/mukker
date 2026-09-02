import Combine
import Foundation

/// Preferences for the window-tiling feature set, backed by `UserDefaults`;
/// published properties persist on change (the same shape as
/// `KeepAwakeSettings`). There is no live state to keep here — `WindowTiler`
/// reads a window, moves it and forgets it.
@MainActor
final class WindowTilingSettings: ObservableObject {
    static let shared = WindowTilingSettings()

    private let defaults: UserDefaults

    /// Whether the four tiling hotkeys are registered at all. On by default.
    /// Turning it off makes `HotKeyManager` drop the registrations entirely, so
    /// ⌃⌘arrows go back to whatever else wants them rather than being swallowed.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: K.enabled) }
    }

    /// Points inset on every edge of a tiled window. Two windows tiled side by
    /// side therefore sit `2 × gap` apart. Zero out of the box.
    @Published var gap: CGFloat {
        didSet { defaults.set(Double(gap), forKey: K.gap) }
    }

    /// Widest gap the settings pane offers — beyond this a half stops being a
    /// useful window on a small display.
    static let maximumGap: CGFloat = 64

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A plain `defaults.bool(forKey:)` cannot express default-on.
        isEnabled = defaults.object(forKey: K.enabled) as? Bool ?? true
        gap = (defaults.object(forKey: K.gap) as? Double).map { CGFloat($0) } ?? 0
    }

    private enum K {
        static let enabled = "windowTilingEnabled"
        static let gap = "windowTilingGap"
    }
}
