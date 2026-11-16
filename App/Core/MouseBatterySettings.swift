import Combine
import Foundation

/// Preferences for the Razer mouse battery readout (same shape as
/// `KeepAwakeSettings`). The live reading belongs to `MouseBatteryService`.
@MainActor
final class MouseBatterySettings: ObservableObject {
    static let shared = MouseBatterySettings()

    /// Below this percentage (and not charging) the menu opens with a warning row.
    nonisolated static let lowThreshold = 15

    private let defaults: UserDefaults

    /// Poll a connected Razer mouse and show it in the menu. On by default.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: K.enabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: K.enabled) as? Bool ?? true
    }

    private enum K {
        static let enabled = "mouseBattery.enabled"
    }
}
