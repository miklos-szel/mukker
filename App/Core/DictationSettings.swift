import Combine
import Foundation

/// What starts dictation. A modifier pressed on its own can't be a Carbon
/// hotkey, so `.fn` and `.rightOption` are watched by `DictationKeyMonitor`;
/// `.combo` is an ordinary global hotkey (`ShortcutSettings.dictationCombo`).
enum DictationTrigger: String, CaseIterable, Identifiable {
    case fn
    case rightOption
    case combo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "fn / 🌐 key"
        case .rightOption: return "Right ⌥ Option"
        case .combo: return "Custom shortcut"
        }
    }
}

/// How a press of the trigger maps onto recording.
enum DictationActivation: String, CaseIterable, Identifiable {
    /// Held past the threshold: push-to-talk. A shorter tap latches recording
    /// on until the next press.
    case holdOrToggle
    case pushToTalk
    case toggle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .holdOrToggle: return "Hold to talk, or tap to start/stop"
        case .pushToTalk: return "Hold to talk"
        case .toggle: return "Tap to start, tap again to stop"
        }
    }
}

/// How long a loaded model stays in memory after the last dictation.
enum DictationUnloadDelay: Int, CaseIterable, Identifiable {
    case immediately = 0
    case twoMinutes = 120
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600
    case never = -1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .immediately: return "Immediately"
        case .twoMinutes: return "After 2 minutes"
        case .fiveMinutes: return "After 5 minutes"
        case .fifteenMinutes: return "After 15 minutes"
        case .oneHour: return "After 1 hour"
        case .never: return "Never"
        }
    }
}

/// Preferences for Dictation, backed by `UserDefaults`; published properties
/// persist on change (the `TranslationSettings` shape). The custom combo lives
/// in `ShortcutSettings` with every other global hotkey.
@MainActor
final class DictationSettings: ObservableObject {
    static let shared = DictationSettings()

    private let defaults: UserDefaults

    /// On by default; nothing happens until a model has been downloaded anyway.
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: K.enabled) } }
    @Published var trigger: DictationTrigger { didSet { defaults.set(trigger.rawValue, forKey: K.trigger) } }
    @Published var activation: DictationActivation { didSet { defaults.set(activation.rawValue, forKey: K.activation) } }
    @Published var modelID: String { didSet { defaults.set(modelID, forKey: K.model) } }
    /// nil is "Automatic".
    @Published var language: DictationLanguage? {
        didSet { defaults.set(language?.rawValue ?? "auto", forKey: K.language) }
    }
    /// The languages the user speaks; Automatic only chooses among these.
    @Published var preferredLanguages: [DictationLanguage] {
        didSet { defaults.set(preferredLanguages.map(\.rawValue), forKey: K.preferred) }
    }
    /// A CoreAudio device UID; empty follows the system default input.
    @Published var microphoneUID: String { didSet { defaults.set(microphoneUID, forKey: K.microphone) } }
    /// Extra global shortcuts that dictate in one fixed language (Whisper models only).
    @Published var languageShortcutsEnabled: Bool { didSet { defaults.set(languageShortcutsEnabled, forKey: K.languageShortcuts) } }
    @Published var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: K.sounds) } }
    @Published var soundVolume: Double { didSet { defaults.set(soundVolume, forKey: K.volume) } }
    @Published var overlayEnabled: Bool { didSet { defaults.set(overlayEnabled, forKey: K.overlay) } }
    @Published var appendTrailingSpace: Bool { didSet { defaults.set(appendTrailingSpace, forKey: K.trailingSpace) } }
    @Published var unloadDelay: DictationUnloadDelay { didSet { defaults.set(unloadDelay.rawValue, forKey: K.unload) } }

    /// Shorter than this is a tap, longer a hold (`.holdOrToggle` only).
    nonisolated static let holdThreshold: TimeInterval = 0.3

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: K.enabled) as? Bool ?? true
        trigger = defaults.string(forKey: K.trigger).flatMap(DictationTrigger.init(rawValue:)) ?? .rightOption
        activation = defaults.string(forKey: K.activation).flatMap(DictationActivation.init(rawValue:)) ?? .holdOrToggle
        let storedModel = defaults.string(forKey: K.model) ?? DictationCatalog.defaultModelID
        modelID = DictationCatalog.model(id: storedModel).id
        language = defaults.string(forKey: K.language).flatMap(DictationLanguage.init(rawValue:))
        preferredLanguages = (defaults.stringArray(forKey: K.preferred))
            .map { $0.compactMap(DictationLanguage.init(rawValue:)) }
            ?? Self.defaultPreferredLanguages()
        microphoneUID = defaults.string(forKey: K.microphone) ?? ""
        languageShortcutsEnabled = defaults.object(forKey: K.languageShortcuts) as? Bool ?? false
        soundsEnabled = defaults.object(forKey: K.sounds) as? Bool ?? true
        soundVolume = min(max(defaults.object(forKey: K.volume) as? Double ?? 0.6, 0), 1)
        overlayEnabled = defaults.object(forKey: K.overlay) as? Bool ?? true
        appendTrailingSpace = defaults.object(forKey: K.trailingSpace) as? Bool ?? false
        unloadDelay = (defaults.object(forKey: K.unload) as? Int).flatMap(DictationUnloadDelay.init(rawValue:))
            ?? .fiveMinutes
    }

    var model: DictationModel { DictationCatalog.model(id: modelID) }

    /// English plus the system language, when that is one of the three.
    nonisolated static func defaultPreferredLanguages(
        systemLanguages: [String] = Locale.preferredLanguages) -> [DictationLanguage] {
        var result: [DictationLanguage] = [.english]
        for identifier in systemLanguages {
            let code = String(identifier.prefix(2))
            if let language = DictationLanguage(rawValue: code), !result.contains(language) {
                result.append(language)
            }
        }
        return DictationLanguage.allCases.filter(result.contains)
    }

    private enum K {
        static let enabled = "dictationEnabled"
        static let trigger = "dictationTrigger"
        static let activation = "dictationActivation"
        static let model = "dictationModel"
        static let language = "dictationLanguage"
        static let preferred = "dictationPreferredLanguages"
        static let microphone = "dictationMicrophoneUID"
        static let sounds = "dictationSounds"
        static let languageShortcuts = "dictationLanguageShortcuts"
        static let volume = "dictationSoundVolume"
        static let overlay = "dictationOverlay"
        static let trailingSpace = "dictationTrailingSpace"
        static let unload = "dictationUnloadDelay"
    }
}
