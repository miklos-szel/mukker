import Combine
import Foundation
import SwiftUI

enum RetentionPeriod: String, CaseIterable, Identifiable, Codable {
    case day, week, month, threeMonths, year, forever
    var id: String { rawValue }

    var label: String {
        switch self {
        case .day:         return "24 hours"
        case .week:        return "1 week"
        case .month:       return "1 month"
        case .threeMonths: return "3 months"
        case .year:        return "1 year"
        case .forever:     return "Forever"
        }
    }

    /// Seconds to keep an item. nil means keep forever.
    var seconds: TimeInterval? {
        switch self {
        case .day:         return 24 * 3600
        case .week:        return 7 * 24 * 3600
        case .month:       return 30 * 24 * 3600
        case .threeMonths: return 90 * 24 * 3600
        case .year:        return 365 * 24 * 3600
        case .forever:     return nil
        }
    }
}

enum AppendSeparator: String, CaseIterable, Identifiable, Codable {
    case none, space, newline
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:    return "No separator"
        case .space:   return "Space"
        case .newline: return "New line"
        }
    }

    var literal: String {
        switch self {
        case .none:    return ""
        case .space:   return " "
        case .newline: return "\n"
        }
    }
}

enum MaxClipSize: String, CaseIterable, Identifiable, Codable {
    case k64, k128, k256, k512, m1, m2, unlimited
    var id: String { rawValue }

    var label: String {
        switch self {
        case .k64:       return "64k characters"
        case .k128:      return "128k characters"
        case .k256:      return "256k characters"
        case .k512:      return "512k characters"
        case .m1:        return "1M characters"
        case .m2:        return "2M characters"
        case .unlimited: return "Unlimited"
        }
    }

    /// Maximum number of characters to keep. nil means no limit.
    var characterLimit: Int? {
        switch self {
        case .k64:       return 64_000
        case .k128:      return 128_000
        case .k256:      return 256_000
        case .k512:      return 512_000
        case .m1:        return 1_000_000
        case .m2:        return 2_000_000
        case .unlimited: return nil
        }
    }
}

struct IgnoredApp: Codable, Identifiable, Hashable {
    var bundleID: String
    var displayName: String
    var id: String { bundleID }
}

/// A browser-extension popup whose copies should be treated as sensitive and
/// not stored (identified via the `org.chromium.source-url` pasteboard type).
struct PasswordManagerExtension: Codable, Identifiable, Hashable {
    /// Chromium extension ID (the host of a `chrome-extension://<id>/…` URL).
    var extensionID: String
    var displayName: String
    var id: String { extensionID }
}

/// Single source of truth for clipboard preferences.
///
/// Backed directly by `UserDefaults` with computed properties that fire
/// `objectWillChange` on write. We deliberately avoid `@AppStorage` here:
/// `@AppStorage` only drives view updates when used inside a `View`, not when
/// stored in an observable object, so it would silently fail to refresh
/// observers of this shared object.
@MainActor
final class ClipboardSettings: ObservableObject {
    static let shared = ClipboardSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Generic accessors

    private func boolValue(_ key: String, default def: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? def
    }

    private func setBool(_ value: Bool, _ key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
    }

    private func doubleValue(_ key: String, default def: Double) -> Double {
        defaults.object(forKey: key) as? Double ?? def
    }

    private func setDouble(_ value: Double, _ key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
    }

    private func intValue(_ key: String, default def: Int) -> Int {
        defaults.object(forKey: key) as? Int ?? def
    }

    private func setInt(_ value: Int, _ key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
    }

    private func colorValue(_ key: String, default def: Color) -> Color {
        guard let hex = defaults.string(forKey: key), let color = Color(hex: hex) else { return def }
        return color
    }

    private func setColor(_ value: Color, _ key: String) {
        objectWillChange.send()
        defaults.set(value.hexRGBA, forKey: key)
    }

    private func enumValue<T: RawRepresentable>(_ key: String, default def: T) -> T where T.RawValue == String {
        guard let raw = defaults.string(forKey: key), let v = T(rawValue: raw) else { return def }
        return v
    }

    private func setEnum<T: RawRepresentable>(_ value: T, _ key: String) where T.RawValue == String {
        objectWillChange.send()
        defaults.set(value.rawValue, forKey: key)
    }

    // MARK: Popup

    /// Popup size as a fraction of the available screen (`visibleFrame`).
    /// Clamped to 0.3…0.9 (matching the General-pane slider). Default 0.6.
    var popupSizePercent: Double {
        get { min(max(doubleValue("popup.sizePercent", default: 0.6), 0.3), 0.9) }
        set { setDouble(newValue, "popup.sizePercent") }
    }

    // MARK: Popup appearance

    /// When on, the popup panel uses `popupBackgroundColor` instead of the
    /// appearance-adaptive `PopupTheme.panelBackground`. Off by default.
    var popupCustomBackgroundEnabled: Bool {
        get { boolValue("popup.customBackgroundEnabled", default: true) }
        set { setBool(newValue, "popup.customBackgroundEnabled") }
    }
    /// The user-selected popup background color (used only when
    /// `popupCustomBackgroundEnabled` is on).
    var popupBackgroundColor: Color {
        get { colorValue("popup.backgroundColor", default: ClipboardSettings.defaultPopupBackgroundColor) }
        set { setColor(newValue, "popup.backgroundColor") }
    }

    /// When on, the popup panel draws a colored bezel (border) around its edge.
    /// Off by default.
    var popupBezelEnabled: Bool {
        get { boolValue("popup.bezelEnabled", default: true) }
        set { setBool(newValue, "popup.bezelEnabled") }
    }
    var popupBezelColor: Color {
        get { colorValue("popup.bezelColor", default: ClipboardSettings.defaultPopupBezelColor) }
        set { setColor(newValue, "popup.bezelColor") }
    }
    /// Bezel width in points. Clamped to 0…12 (matching the General-pane slider).
    var popupBezelWidth: Double {
        get { min(max(doubleValue("popup.bezelWidth", default: 7), 0), 12) }
        set { setDouble(newValue, "popup.bezelWidth") }
    }

    static let defaultPopupBackgroundColor = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1)
    static let defaultPopupBezelColor = Color(.sRGB, red: 0.902, green: 0.592, blue: 0.094, opacity: 1)

    // MARK: History

    var keepText: Bool {
        get { boolValue("clip.keepText", default: true) }
        set { setBool(newValue, "clip.keepText") }
    }
    var keepImages: Bool {
        get { boolValue("clip.keepImages", default: true) }
        set { setBool(newValue, "clip.keepImages") }
    }
    var keepFiles: Bool {
        get { boolValue("clip.keepFiles", default: true) }
        set { setBool(newValue, "clip.keepFiles") }
    }
    var textRetention: RetentionPeriod {
        get { enumValue("clip.textRetention", default: .month) }
        set { setEnum(newValue, "clip.textRetention") }
    }
    var imageRetention: RetentionPeriod {
        get { enumValue("clip.imageRetention", default: .month) }
        set { setEnum(newValue, "clip.imageRetention") }
    }
    var fileRetention: RetentionPeriod {
        get { enumValue("clip.fileRetention", default: .month) }
        set { setEnum(newValue, "clip.fileRetention") }
    }
    var moveToTopOnUse: Bool {
        get { boolValue("clip.moveToTopOnUse", default: true) }
        set { setBool(newValue, "clip.moveToTopOnUse") }
    }
    /// Maximum number of clipboard items to retain in the database (oldest unpinned
    /// rows are trimmed). Reuses the legacy "maxHistoryItems" key.
    var maxHistoryItems: Int {
        get { intValue("maxHistoryItems", default: 1000) }
        set { setInt(newValue, "maxHistoryItems") }
    }
    /// When on, selecting an item sends ⌘V to the previously active app; when off,
    /// it only copies to the clipboard. Reuses the legacy "autoPasteEnabled" key.
    var autoPasteEnabled: Bool {
        get { boolValue("autoPasteEnabled", default: true) }
        set { setBool(newValue, "autoPasteEnabled") }
    }
    /// Highlight the active search query inside the history preview. Off by default.
    var highlightSearchMatches: Bool {
        get { boolValue("clip.highlightSearchMatches", default: false) }
        set { setBool(newValue, "clip.highlightSearchMatches") }
    }
    /// Render rich-text clips as plain text in the preview pane (preview only;
    /// pasting still uses the original formatting). Off by default.
    var plainTextPreview: Bool {
        get { boolValue("clip.plainTextPreview", default: false) }
        set { setBool(newValue, "clip.plainTextPreview") }
    }

    // MARK: Merging

    var fastAppendEnabled: Bool {
        get { boolValue("clip.fastAppendEnabled", default: false) }
        set { setBool(newValue, "clip.fastAppendEnabled") }
    }
    var fastAppendBackToPasteboard: Bool {
        get { boolValue("clip.fastAppendBackToPasteboard", default: true) }
        set { setBool(newValue, "clip.fastAppendBackToPasteboard") }
    }
    var appendSeparator: AppendSeparator {
        get { enumValue("clip.appendSeparator", default: .space) }
        set { setEnum(newValue, "clip.appendSeparator") }
    }
    var playAppendSound: Bool {
        get { boolValue("clip.playAppendSound", default: true) }
        set { setBool(newValue, "clip.playAppendSound") }
    }

    // MARK: Advanced

    var maxClipSize: MaxClipSize {
        get { enumValue("clip.maxClipSize", default: .k256) }
        set { setEnum(newValue, "clip.maxClipSize") }
    }

    /// Skip pasteboard contents marked concealed/sensitive by password managers
    /// (the de-facto org.nspasteboard.ConcealedType convention) and copies coming
    /// from a known password-manager browser extension. On by default.
    var ignoreConcealedItems: Bool {
        get { boolValue("clip.ignoreConcealedItems", default: true) }
        set { setBool(newValue, "clip.ignoreConcealedItems") }
    }

    /// Browser extensions whose copies are treated as sensitive (matched against
    /// the `org.chromium.source-url` extension ID). Used only when
    /// `ignoreConcealedItems` is on.
    var passwordManagerExtensions: [PasswordManagerExtension] {
        get {
            guard let data = defaults.data(forKey: "clip.passwordManagerExtensions"),
                  let decoded = try? JSONDecoder().decode([PasswordManagerExtension].self, from: data) else {
                return ClipboardSettings.defaultPasswordManagerExtensions
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "clip.passwordManagerExtensions")
            }
        }
    }

    var passwordManagerExtensionIDs: Set<String> {
        Set(passwordManagerExtensions.map(\.extensionID))
    }

    func resetPasswordManagerExtensions() {
        passwordManagerExtensions = ClipboardSettings.defaultPasswordManagerExtensions
    }

    /// When on, text items about to be deleted (retention expiry or max-items trim)
    /// are first written as .txt files to `foreverHistoryDirectory`.
    var foreverHistoryEnabled: Bool {
        get { boolValue("clip.foreverHistoryEnabled", default: false) }
        set { setBool(newValue, "clip.foreverHistoryEnabled") }
    }
    var foreverHistoryDirectory: String {
        get { defaults.string(forKey: "clip.foreverHistoryDirectory") ?? AppPaths.defaultForeverHistoryDirectory.path }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "clip.foreverHistoryDirectory") }
    }

    var ignoredApps: [IgnoredApp] {
        get {
            guard let data = defaults.data(forKey: "clip.ignoredApps"),
                  let decoded = try? JSONDecoder().decode([IgnoredApp].self, from: data) else {
                return ClipboardSettings.defaultIgnoredApps
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "clip.ignoredApps")
            }
        }
    }

    var ignoredBundleIDs: Set<String> {
        Set(ignoredApps.map(\.bundleID))
    }

    func resetIgnoredApps() {
        ignoredApps = ClipboardSettings.defaultIgnoredApps
    }

    // MARK: Derived helpers

    func retention(for kind: ClipKind) -> RetentionPeriod {
        switch kind {
        case .text:  return textRetention
        case .image: return imageRetention
        case .file:  return fileRetention
        }
    }

    func isKindEnabled(_ kind: ClipKind) -> Bool {
        switch kind {
        case .text:  return keepText
        case .image: return keepImages
        case .file:  return keepFiles
        }
    }

    static let defaultIgnoredApps: [IgnoredApp] = [
        IgnoredApp(bundleID: "com.apple.keychainaccess", displayName: "Keychain Access"),
        IgnoredApp(bundleID: "com.apple.SecurityAgent", displayName: "SecurityAgent"),
        IgnoredApp(bundleID: "com.1password.1password", displayName: "1Password"),
        IgnoredApp(bundleID: "com.agilebits.onepassword7", displayName: "1Password 7"),
        IgnoredApp(bundleID: "com.apple.Passwords", displayName: "Passwords"),
        IgnoredApp(bundleID: "com.apple.wallet", displayName: "Wallet"),
    ]

    /// Chromium extension IDs of known password managers (same IDs across Chrome,
    /// Brave, and Edge). 1Password is verified empirically; the rest are best-effort.
    static let defaultPasswordManagerExtensions: [PasswordManagerExtension] = [
        PasswordManagerExtension(extensionID: "aeblfdkhhhdcdjpifhhbdiojplfjncoa", displayName: "1Password"),
        PasswordManagerExtension(extensionID: "nngceckbapebfimnlniiiahkandclblb", displayName: "Bitwarden"),
        PasswordManagerExtension(extensionID: "hdokiejnpimakedhajhdlcegeplioahd", displayName: "LastPass"),
        PasswordManagerExtension(extensionID: "fdjamakpfbbddfjaooikfcpapjohcfmg", displayName: "Dashlane"),
        PasswordManagerExtension(extensionID: "ghmbeldphafepmbegfdlkpapadhbakde", displayName: "Proton Pass"),
        PasswordManagerExtension(extensionID: "fooolghllnmhmmndgjiamiiodkpenpbb", displayName: "NordPass"),
        PasswordManagerExtension(extensionID: "bfogiafebfohielmmehodmfbbebbbpei", displayName: "Keeper"),
        PasswordManagerExtension(extensionID: "pnlccmojcmeohlpggmfnbbiapkmbliob", displayName: "RoboForm"),
    ]
}
