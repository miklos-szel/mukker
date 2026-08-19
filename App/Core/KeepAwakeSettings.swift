import Combine
import Foundation

/// How long a single activation of Keep Awake lasts. Raw value is **minutes**,
/// with `0` meaning "until turned off" — storing the minute count keeps the
/// persisted value readable and lets new durations be added without a migration.
enum KeepAwakeDuration: Int, CaseIterable, Identifiable {
    case indefinite = 0
#if DEBUG
    /// Debug builds only — makes the expiry path testable without a 5-minute wait.
    case oneMinute = 1
#endif
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60
    case twoHours = 120
    case fiveHours = 300

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .indefinite: return "Until turned off"
#if DEBUG
        case .oneMinute: return "1 minute (debug)"
#endif
        case .fiveMinutes: return "5 minutes"
        case .tenMinutes: return "10 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .fiveHours: return "5 hours"
        }
    }

    /// Seconds this duration lasts, or nil when it never expires on its own.
    var interval: TimeInterval? {
        self == .indefinite ? nil : TimeInterval(rawValue * 60)
    }
}

/// Preferences for the Keep Awake feature, backed by `UserDefaults`; published
/// properties persist on change (same shape as `CaptureSettings`). The live
/// on/off state is **not** here — that belongs to `KeepAwakeService`, which is
/// the single owner of the power assertion.
@MainActor
final class KeepAwakeSettings: ObservableObject {
    static let shared = KeepAwakeSettings()

    private let defaults: UserDefaults

    /// How long "Turn On" keeps the Mac awake. Two hours out of the box.
    @Published var defaultDuration: KeepAwakeDuration {
        didSet { defaults.set(defaultDuration.rawValue, forKey: K.duration) }
    }

    /// Turn Keep Awake on automatically when the app launches. Off by default.
    @Published var activateAtLaunch: Bool {
        didSet { defaults.set(activateAtLaunch, forKey: K.atLaunch) }
    }

    /// Let the screen sleep while still keeping the machine running — useful for
    /// a long job you don't need to watch. Off by default (the display stays on).
    @Published var allowDisplaySleep: Bool {
        didSet { defaults.set(allowDisplaySleep, forKey: K.allowDisplaySleep) }
    }

    /// Turn Keep Awake off when the user puts the Mac to sleep by hand — an
    /// explicit sleep should win over an assertion the user forgot about. On by default.
    @Published var deactivateOnManualSleep: Bool {
        didSet { defaults.set(deactivateOnManualSleep, forKey: K.deactivateOnSleep) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // An unknown stored raw value (older/newer build, hand-edited defaults)
        // falls back to the default duration rather than an unusable state.
        defaultDuration = (defaults.object(forKey: K.duration) as? Int)
            .flatMap(KeepAwakeDuration.init(rawValue:)) ?? .twoHours
        activateAtLaunch = defaults.bool(forKey: K.atLaunch)
        allowDisplaySleep = defaults.bool(forKey: K.allowDisplaySleep)
        deactivateOnManualSleep = defaults.object(forKey: K.deactivateOnSleep) as? Bool ?? true
    }

    private enum K {
        static let duration = "keepAwakeDefaultDuration"
        static let atLaunch = "keepAwakeActivateAtLaunch"
        static let allowDisplaySleep = "keepAwakeAllowDisplaySleep"
        static let deactivateOnSleep = "keepAwakeDeactivateOnManualSleep"
    }
}
