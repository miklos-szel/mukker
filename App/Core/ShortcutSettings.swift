import AppKit
import Combine
import HotKey

/// Every global (system-wide) shortcut in one observable object: the popup from
/// the clipboard/snippets side, the three capture shortcuts and the four window
/// tiling shortcuts. `HotKeyManager` subscribes to all of them, the settings
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

    static let defaultPopupCombo = KeyCombo(key: .e, modifiers: [.command])
    static let defaultAreaCombo = KeyCombo(key: .four, modifiers: [.command, .shift, .control])
    static let defaultFullscreenCombo = KeyCombo(key: .three, modifiers: [.command, .shift, .control])
    static let defaultScrollCombo = KeyCombo(key: .five, modifiers: [.command, .shift, .control])

    static let defaultTileLeftCombo = KeyCombo(key: .leftArrow, modifiers: [.control, .command])
    static let defaultTileRightCombo = KeyCombo(key: .rightArrow, modifiers: [.control, .command])
    // The vertical pair is deliberately "inverted" — top is ⌃⌘↓ and bottom is
    // ⌃⌘↑, matching the layout the user asked for. Do not "fix" it.
    static let defaultTileTopCombo = KeyCombo(key: .downArrow, modifiers: [.control, .command])
    static let defaultTileBottomCombo = KeyCombo(key: .upArrow, modifiers: [.control, .command])

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
    }

    /// Emits whenever any combo changes — the manager's re-register signal.
    ///
    /// `dropFirst` has to match the number of merged publishers exactly, because
    /// `@Published` replays its current value on subscribe: too low and the
    /// manager re-registers spuriously at launch, too high and the first real
    /// edit is swallowed. Keep the two in step when adding a combo.
    var comboChanges: AnyPublisher<Void, Never> {
        let publishers = [$popupCombo, $areaCombo, $fullscreenCombo, $scrollCombo,
                          $tileLeftCombo, $tileRightCombo, $tileTopCombo, $tileBottomCombo]
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
    }
}
