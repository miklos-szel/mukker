import AppKit
import Combine
import HotKey
import SwiftUI

/// Registers all system-wide global hotkeys (via the Carbon-backed `HotKey`
/// package) so they fire even when the app is not frontmost. Combos come from
/// `ShortcutSettings` and are re-registered whenever the user changes them. The
/// `HotKey` objects must be retained for the shortcuts to stay live, so they're
/// held here.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeys: [HotKey] = []
    private var cancellables: Set<AnyCancellable> = []
    private var settings: ShortcutSettings?
    private var handlers: [(KeyPath<ShortcutSettings, KeyCombo>, () -> Void)] = []

    /// Wires the action handlers and registers the current combos, then keeps the
    /// registration in sync with `ShortcutSettings` changes.
    func start(settings: ShortcutSettings,
               popup: @escaping () -> Void,
               area: @escaping () -> Void,
               screen: @escaping () -> Void,
               scroll: @escaping () -> Void) {
        self.settings = settings
        handlers = [
            (\.popupCombo, popup),
            (\.areaCombo, area),
            (\.fullscreenCombo, screen),
            (\.scrollCombo, scroll)
        ]
        reload()

        settings.comboChanges
            .sink { [weak self] in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        guard let settings else { return }
        hotKeys.removeAll()
        for (combo, action) in handlers {
            let key = HotKey(keyCombo: settings[keyPath: combo])
            key.keyDownHandler = action
            hotKeys.append(key)
        }
        Log.hotkey.info("registered \(self.hotKeys.count) global hotkeys")
    }
}

extension KeyCombo {
    /// The SwiftUI key for this combo's key, if any (lowercased so it doesn't
    /// imply an extra Shift). Cosmetic — the live hotkey is the Carbon one.
    var swiftUIKeyEquivalent: KeyEquivalent? {
        guard let char = key?.description.lowercased().first else { return nil }
        return KeyEquivalent(char)
    }

    /// This combo's modifier flags as SwiftUI `EventModifiers`.
    var swiftUIModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    /// Glyph string like "⌃⇧⌘4" for display in settings and menus.
    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += key?.description.uppercased() ?? ""
        return s
    }
}
