import AppKit
import Combine
import HotKey

/// Every global (system-wide) shortcut in one observable object: the popup from
/// the clipboard/snippets side and the three capture shortcuts. `HotKeyManager`
/// subscribes to all four, the Hotkeys settings tab edits them, and the menu-bar
/// menu derives its glyphs from them — so the three never drift apart.
@MainActor
final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()

    private let defaults: UserDefaults

    /// Shows/hides the clipboard + snippets popup. Default ⌘E.
    @Published var popupCombo: KeyCombo { didSet { defaults.set(popupCombo.dictionary, forKey: K.popup) } }
    @Published var areaCombo: KeyCombo { didSet { defaults.set(areaCombo.dictionary, forKey: K.area) } }
    @Published var fullscreenCombo: KeyCombo { didSet { defaults.set(fullscreenCombo.dictionary, forKey: K.full) } }
    @Published var scrollCombo: KeyCombo { didSet { defaults.set(scrollCombo.dictionary, forKey: K.scroll) } }

    static let defaultPopupCombo = KeyCombo(key: .e, modifiers: [.command])
    static let defaultAreaCombo = KeyCombo(key: .four, modifiers: [.command, .shift, .control])
    static let defaultFullscreenCombo = KeyCombo(key: .three, modifiers: [.command, .shift, .control])
    static let defaultScrollCombo = KeyCombo(key: .five, modifiers: [.command, .shift, .control])

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        popupCombo = Self.combo(from: defaults, key: K.popup) ?? Self.defaultPopupCombo
        areaCombo = Self.combo(from: defaults, key: K.area) ?? Self.defaultAreaCombo
        fullscreenCombo = Self.combo(from: defaults, key: K.full) ?? Self.defaultFullscreenCombo
        scrollCombo = Self.combo(from: defaults, key: K.scroll) ?? Self.defaultScrollCombo
    }

    /// Emits whenever any of the four combos changes — the manager's re-register signal.
    var comboChanges: AnyPublisher<Void, Never> {
        Publishers.Merge4($popupCombo.map { _ in () },
                          $areaCombo.map { _ in () },
                          $fullscreenCombo.map { _ in () },
                          $scrollCombo.map { _ in () })
            .dropFirst(4)   // @Published emits the current value on subscribe
            .eraseToAnyPublisher()
    }

    func resetToDefaults() {
        popupCombo = Self.defaultPopupCombo
        areaCombo = Self.defaultAreaCombo
        fullscreenCombo = Self.defaultFullscreenCombo
        scrollCombo = Self.defaultScrollCombo
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
    }
}
