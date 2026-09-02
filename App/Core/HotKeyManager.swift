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

    /// One registerable shortcut: where its combo lives in `ShortcutSettings`,
    /// whether it currently wants to be registered, and what it does. Actions
    /// whose `isEnabled` returns false are skipped entirely rather than
    /// registered-and-ignored, so their combo stays available to other apps.
    struct Action {
        let combo: KeyPath<ShortcutSettings, KeyCombo>
        var isEnabled: () -> Bool = { true }
        let handler: () -> Void

        init(combo: KeyPath<ShortcutSettings, KeyCombo>,
             isEnabled: @escaping () -> Bool = { true },
             handler: @escaping () -> Void) {
            self.combo = combo
            self.isEnabled = isEnabled
            self.handler = handler
        }
    }

    private var hotKeys: [HotKey] = []
    private var cancellables: Set<AnyCancellable> = []
    private var settings: ShortcutSettings?
    private var actions: [Action] = []

    /// Wires the action handlers and registers the current combos, then keeps the
    /// registration in sync with `ShortcutSettings` changes. `reloadOn` is an
    /// extra re-register trigger for anything outside `ShortcutSettings` that can
    /// flip an action's `isEnabled` — the window-tiling on/off switch.
    ///
    /// Called exactly once, from `AppDelegate`: `actions` is assigned, not
    /// appended, so a second call would silently drop the first set.
    func start(settings: ShortcutSettings,
               actions: [Action],
               reloadOn: AnyPublisher<Void, Never>? = nil) {
        self.settings = settings
        self.actions = actions
        reload()

        settings.comboChanges
            .sink { [weak self] in self?.reload() }
            .store(in: &cancellables)

        reloadOn?
            .sink { [weak self] in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        guard let settings else { return }
        // Dropping a `HotKey` is what deregisters it — the object *is* the
        // registration.
        hotKeys.removeAll()
        for action in actions where action.isEnabled() {
            let key = HotKey(keyCombo: settings[keyPath: action.combo])
            key.keyDownHandler = action.handler
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

    /// This combo's key as an `NSMenuItem.keyEquivalent` string. Lowercased so it
    /// doesn't imply an extra Shift, and mapped explicitly for the keys whose
    /// `description` is a glyph rather than the character AppKit expects.
    /// Cosmetic — a status menu's key equivalents only fire while the menu is
    /// open; the live hotkey is the Carbon one.
    var nsKeyEquivalent: String {
        guard let key else { return "" }
        switch key {
        case .leftArrow: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case .rightArrow: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case .upArrow: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case .downArrow: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case .return, .keypadEnter: return "\r"
        case .tab: return "\t"
        case .space: return " "
        case .delete: return String(UnicodeScalar(NSBackspaceCharacter)!)
        case .forwardDelete: return String(UnicodeScalar(NSDeleteFunctionKey)!)
        case .escape: return "\u{1b}"
        case .home: return String(UnicodeScalar(NSHomeFunctionKey)!)
        case .end: return String(UnicodeScalar(NSEndFunctionKey)!)
        case .pageUp: return String(UnicodeScalar(NSPageUpFunctionKey)!)
        case .pageDown: return String(UnicodeScalar(NSPageDownFunctionKey)!)
        case .help: return String(UnicodeScalar(NSHelpFunctionKey)!)
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
             .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            // "F5" would be a two-character key equivalent, which AppKit ignores.
            let index = Int(key.description.dropFirst()) ?? 1
            return String(UnicodeScalar(NSF1FunctionKey + index - 1)!)
        default: return key.description.lowercased()
        }
    }
}
