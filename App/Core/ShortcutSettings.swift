import AppKit
import Combine
import HotKey

/// Every global (system-wide) shortcut in one observable object: the popup from
/// the clipboard/snippets side, the three capture shortcuts, the four window
/// tiling shortcuts, the four translate shortcuts, the optional dictation shortcut and its three per-language variants. `HotKeyManager` subscribes to all of them, the settings
/// panes edit them, and the menu-bar menu derives its glyphs from them — so the
/// three never drift apart.
@MainActor
final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()

    private let defaults: UserDefaults

    /// Shows/hides the clipboard + snippets popup. Default ⌘E.
    @Published var popupCombo: KeyCombo { didSet { defaults.set(popupCombo.dictionary, forKey: K.popup) } }
    @Published var areaCombo: KeyCombo { didSet { defaults.set(areaCombo.dictionary, forKey: K.area) } }
    @Published var fullscreenCombo: KeyCombo { didSet { defaults.set(fullscreenCombo.dictionary, forKey: K.full) } }
    @Published var scrollCombo: KeyCombo { didSet { defaults.set(scrollCombo.dictionary, forKey: K.scroll) } }

    @Published var tileLeftCombo: KeyCombo { didSet { defaults.set(tileLeftCombo.dictionary, forKey: K.tileLeft) } }
    @Published var tileRightCombo: KeyCombo { didSet { defaults.set(tileRightCombo.dictionary, forKey: K.tileRight) } }
    @Published var tileTopCombo: KeyCombo { didSet { defaults.set(tileTopCombo.dictionary, forKey: K.tileTop) } }
    @Published var tileBottomCombo: KeyCombo { didSet { defaults.set(tileBottomCombo.dictionary, forKey: K.tileBottom) } }

    @Published var translateEnglishCombo: KeyCombo { didSet { defaults.set(translateEnglishCombo.dictionary, forKey: K.translateEnglish) } }
    @Published var translateHungarianCombo: KeyCombo { didSet { defaults.set(translateHungarianCombo.dictionary, forKey: K.translateHungarian) } }
    @Published var translateGermanCombo: KeyCombo { didSet { defaults.set(translateGermanCombo.dictionary, forKey: K.translateGerman) } }
    /// Translates into the default target for the detected source language
    /// (`TranslationSettings.defaultTargets`). Default ⌥⇧⌘E.
    @Published var translateAutoCombo: KeyCombo { didSet { defaults.set(translateAutoCombo.dictionary, forKey: K.translateAuto) } }

    /// Used only when Dictation's trigger is "Custom shortcut" (the default
    /// trigger, fn alone, can't be a Carbon hotkey). Default ⌥Space.
    @Published var dictationCombo: KeyCombo { didSet { defaults.set(dictationCombo.dictionary, forKey: K.dictation) } }

    static let defaultPopupCombo = KeyCombo(key: .e, modifiers: [.command])
    static let defaultAreaCombo = KeyCombo(key: .four, modifiers: [.command, .shift, .control])
    static let defaultFullscreenCombo = KeyCombo(key: .three, modifiers: [.command, .shift, .control])
    static let defaultScrollCombo = KeyCombo(key: .five, modifiers: [.command, .shift, .control])

    /// Dictation forced to one language (Whisper models only); off unless
    /// `DictationSettings.languageShortcutsEnabled`. Defaults ⌃⌥E / ⌃⌥G / ⌃⌥H.
    @Published var dictationEnglishCombo: KeyCombo { didSet { defaults.set(dictationEnglishCombo.dictionary, forKey: K.dictationEnglish) } }
    @Published var dictationGermanCombo: KeyCombo { didSet { defaults.set(dictationGermanCombo.dictionary, forKey: K.dictationGerman) } }
    @Published var dictationHungarianCombo: KeyCombo { didSet { defaults.set(dictationHungarianCombo.dictionary, forKey: K.dictationHungarian) } }

    static let defaultTileLeftCombo = KeyCombo(key: .leftArrow, modifiers: [.control, .command])
    static let defaultTileRightCombo = KeyCombo(key: .rightArrow, modifiers: [.control, .command])
    // The vertical pair is deliberately "inverted" — top is ⌃⌘↓ and bottom is
    // ⌃⌘↑, matching the layout the user asked for. Do not "fix" it.
    static let defaultTileTopCombo = KeyCombo(key: .downArrow, modifiers: [.control, .command])
    static let defaultTileBottomCombo = KeyCombo(key: .upArrow, modifiers: [.control, .command])

    static let defaultTranslateEnglishCombo = KeyCombo(key: .e, modifiers: [.command, .shift])
    static let defaultTranslateHungarianCombo = KeyCombo(key: .e, modifiers: [.command, .option])
    static let defaultTranslateGermanCombo = KeyCombo(key: .e, modifiers: [.command, .control])
    static let defaultTranslateAutoCombo = KeyCombo(key: .e, modifiers: [.command, .option, .shift])

    static let defaultDictationCombo = KeyCombo(key: .space, modifiers: [.option])

    static let defaultDictationEnglishCombo = KeyCombo(key: .e, modifiers: [.control, .option])
    static let defaultDictationGermanCombo = KeyCombo(key: .g, modifiers: [.control, .option])
    static let defaultDictationHungarianCombo = KeyCombo(key: .h, modifiers: [.control, .option])

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        popupCombo = Self.combo(from: defaults, key: K.popup) ?? Self.defaultPopupCombo
        areaCombo = Self.combo(from: defaults, key: K.area) ?? Self.defaultAreaCombo
        fullscreenCombo = Self.combo(from: defaults, key: K.full) ?? Self.defaultFullscreenCombo
        scrollCombo = Self.combo(from: defaults, key: K.scroll) ?? Self.defaultScrollCombo

        tileLeftCombo = Self.combo(from: defaults, key: K.tileLeft) ?? Self.defaultTileLeftCombo
        tileRightCombo = Self.combo(from: defaults, key: K.tileRight) ?? Self.defaultTileRightCombo
        tileTopCombo = Self.combo(from: defaults, key: K.tileTop) ?? Self.defaultTileTopCombo
        tileBottomCombo = Self.combo(from: defaults, key: K.tileBottom) ?? Self.defaultTileBottomCombo

        translateEnglishCombo = Self.combo(from: defaults, key: K.translateEnglish) ?? Self.defaultTranslateEnglishCombo
        translateHungarianCombo = Self.combo(from: defaults, key: K.translateHungarian) ?? Self.defaultTranslateHungarianCombo
        translateGermanCombo = Self.combo(from: defaults, key: K.translateGerman) ?? Self.defaultTranslateGermanCombo
        translateAutoCombo = Self.combo(from: defaults, key: K.translateAuto) ?? Self.defaultTranslateAutoCombo

        dictationCombo = Self.combo(from: defaults, key: K.dictation) ?? Self.defaultDictationCombo
        dictationEnglishCombo = Self.combo(from: defaults, key: K.dictationEnglish) ?? Self.defaultDictationEnglishCombo
        dictationGermanCombo = Self.combo(from: defaults, key: K.dictationGerman) ?? Self.defaultDictationGermanCombo
        dictationHungarianCombo = Self.combo(from: defaults, key: K.dictationHungarian) ?? Self.defaultDictationHungarianCombo
    }

    /// Emits whenever any combo changes — the manager's re-register signal.
    ///
    /// `dropFirst` has to match the number of merged publishers exactly, because
    /// `@Published` replays its current value on subscribe: too low and the
    /// manager re-registers spuriously at launch, too high and the first real
    /// edit is swallowed. Keep the two in step when adding a combo.
    var comboChanges: AnyPublisher<Void, Never> {
        let publishers = [$popupCombo, $areaCombo, $fullscreenCombo, $scrollCombo,
                          $tileLeftCombo, $tileRightCombo, $tileTopCombo, $tileBottomCombo,
                          $translateEnglishCombo, $translateHungarianCombo, $translateGermanCombo,
                          $translateAutoCombo,
                          $dictationCombo, $dictationEnglishCombo, $dictationGermanCombo,
                          $dictationHungarianCombo]
            .map { $0.map { _ in () }.eraseToAnyPublisher() }
        return Publishers.MergeMany(publishers)
            .dropFirst(publishers.count)
            .eraseToAnyPublisher()
    }

    func resetToDefaults() {
        popupCombo = Self.defaultPopupCombo
        areaCombo = Self.defaultAreaCombo
        fullscreenCombo = Self.defaultFullscreenCombo
        scrollCombo = Self.defaultScrollCombo
        tileLeftCombo = Self.defaultTileLeftCombo
        tileRightCombo = Self.defaultTileRightCombo
        tileTopCombo = Self.defaultTileTopCombo
        tileBottomCombo = Self.defaultTileBottomCombo
        translateEnglishCombo = Self.defaultTranslateEnglishCombo
        translateHungarianCombo = Self.defaultTranslateHungarianCombo
        translateGermanCombo = Self.defaultTranslateGermanCombo
        translateAutoCombo = Self.defaultTranslateAutoCombo
        dictationCombo = Self.defaultDictationCombo
        dictationEnglishCombo = Self.defaultDictationEnglishCombo
        dictationGermanCombo = Self.defaultDictationGermanCombo
        dictationHungarianCombo = Self.defaultDictationHungarianCombo
    }

    private static func combo(from defaults: UserDefaults, key: String) -> KeyCombo? {
        guard let dict = defaults.dictionary(forKey: key) else { return nil }
        return KeyCombo(dictionary: dict)
    }

    private enum K {
        static let popup = "popupCombo"
        static let area = "areaCombo"
        static let full = "fullscreenCombo"
        static let scroll = "scrollCombo"
        static let tileLeft = "tileLeftCombo"
        static let tileRight = "tileRightCombo"
        static let tileTop = "tileTopCombo"
        static let tileBottom = "tileBottomCombo"
        static let translateEnglish = "translateEnglishCombo"
        static let translateHungarian = "translateHungarianCombo"
        static let translateGerman = "translateGermanCombo"
        static let translateAuto = "translateAutoCombo"
        static let dictation = "dictationCombo"
        static let dictationEnglish = "dictationEnglishCombo"
        static let dictationGerman = "dictationGermanCombo"
        static let dictationHungarian = "dictationHungarianCombo"
    }
}
