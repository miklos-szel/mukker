import Combine
import Foundation

/// Preferences for the Razer mouse battery readout (same shape as
/// `KeepAwakeSettings`). The live reading belongs to `MouseBatteryService`.
@MainActor
final class MouseBatterySettings: ObservableObject {
    static let shared = MouseBatterySettings()

    /// The choices offered in Settings, and the out-of-the-box value. Capped
    /// at 40 so the orange "getting low" band (below 50%) always exists.
    nonisolated static let thresholdChoices = [5, 10, 15, 20, 25, 30, 35, 40]
    nonisolated static let defaultThreshold = 15

    private let defaults: UserDefaults

    /// Poll a connected Razer mouse and show it in the menu. On by default.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: K.enabled) }
    }

    /// Below this percentage (and not charging) the menu opens with a warning
    /// row and the reading turns red.
    @Published var lowThreshold: Int {
        didSet { defaults.set(lowThreshold, forKey: K.threshold) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: K.enabled) as? Bool ?? true
        // An out-of-range stored value (hand-edited defaults) falls back.
        let stored = defaults.object(forKey: K.threshold) as? Int
        lowThreshold = stored.flatMap { Self.thresholdChoices.contains($0) ? $0 : nil } ?? Self.defaultThreshold
    }

    private enum K {
        static let enabled = "mouseBattery.enabled"
        static let threshold = "mouseBattery.lowThreshold"
    }
}
