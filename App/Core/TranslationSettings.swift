import AppKit
import Combine
import Foundation
import NaturalLanguage
import SwiftUI

/// The languages the translate hotkeys aim at. The source language is never
/// chosen — the model detects it — so this only names the *target*.
enum TranslationLanguage: String, CaseIterable, Identifiable {
    case english
    case hungarian
    case german

    var id: String { rawValue }

    /// Shown in the panel, the menu and the settings pane, and also the name
    /// the prompt uses — a plain English language name is what the model reads
    /// most reliably.
    var label: String {
        switch self {
        case .english: return "English"
        case .hungarian: return "Hungarian"
        case .german: return "German"
        }
    }

    /// Accepts the short codes the `MUKKER_TRANSLATE=en|hu|de` debug hook uses,
    /// so a scripted run doesn't have to spell out the case name.
    init?(shortCode: String) {
        switch shortCode.lowercased() {
        case "en": self = .english
        case "hu": self = .hungarian
        case "de": self = .german
        default: return nil
        }
    }
}

/// The source languages the automatic translate shortcut tells apart, each
/// with its own default target in Settings. `other` covers everything else —
/// and text too short or mixed to call.
enum TranslationSourceLanguage: String, CaseIterable, Identifiable {
    case english
    case german
    case hungarian
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .english: return "English"
        case .german: return "German"
        case .hungarian: return "Hungarian"
        case .other: return "Other languages"
        }
    }

    /// Hungarian from English and German, German from Hungarian — the
    /// user's own choice; anything unrecognised goes to Hungarian.
    var defaultTarget: TranslationLanguage {
        switch self {
        case .hungarian: return .german
        case .english, .german, .other: return .hungarian
        }
    }

    /// Detects the language of `text` on the Mac (NaturalLanguage, nothing
    /// is sent anywhere). Only a confident English/German/Hungarian answer
    /// counts; anything else is `.other`.
    nonisolated static func detect(_ text: String) -> TranslationSourceLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.3 else { return .other }
        switch language {
        case .english: return .english
        case .german: return .german
        case .hungarian: return .hungarian
        default: return .other
        }
    }
}

/// Which command-line client carries the text to a model. Both are used
/// signed in with the user's own subscription (ChatGPT for Codex, Claude for
/// Claude Code), so neither needs an API key in the app.
enum TranslationBackend: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    /// The picker label in Settings.
    var label: String {
        switch self {
        case .codex: return "ChatGPT (Codex CLI)"
        case .claude: return "Claude (Claude Code CLI)"
        }
    }

    /// The short name the panel header shows next to the target language.
    var shortName: String {
        switch self {
        case .codex: return "ChatGPT"
        case .claude: return "Claude"
        }
    }

    /// The company the text is sent to — named in the settings footer, since
    /// sending clipboard text off the Mac is the one thing the user must know.
    var provider: String {
        switch self {
        case .codex: return "OpenAI"
        case .claude: return "Anthropic"
        }
    }

    var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        }
    }

    /// Where each CLI's installers put it, most likely first. A GUI app gets
    /// no shell PATH, so these are probed directly. Claude Code's native
    /// installer uses `~/.local/bin`; Codex is usually a Homebrew install.
    func defaultCandidates(home: String = NSHomeDirectory()) -> [String] {
        switch self {
        case .codex:
            return ["/opt/homebrew/bin/codex",
                    "/usr/local/bin/codex",
                    "\(home)/.local/bin/codex",
                    "\(home)/.npm-global/bin/codex"]
        case .claude:
            return ["\(home)/.local/bin/claude",
                    "/opt/homebrew/bin/claude",
                    "/usr/local/bin/claude",
                    "\(home)/.claude/local/claude"]
        }
    }

    /// How to get the CLI at all.
    var installHint: String {
        switch self {
        case .codex: return "Install it with `brew install codex`, then run `codex login` in Terminal."
        case .claude: return "Install Claude Code (`curl -fsSL https://claude.ai/install.sh | bash`), "
            + "then run `claude` once in Terminal and sign in with `/login`."
        }
    }

    /// How to fix a missing or expired sign-in.
    var loginHint: String {
        switch self {
        case .codex: return "Run `codex login` in Terminal, then try again."
        case .claude: return "Run `claude` in Terminal and sign in with `/login`, then try again."
        }
    }

    /// Model used when the user hasn't set one. Codex's own default follows
    /// the ChatGPT plan; for Claude a mid-size model is plenty for translation
    /// and answers faster than the CLI's default.
    var defaultModel: String {
        switch self {
        case .codex: return ""
        case .claude: return "sonnet"
        }
    }
}

/// Preferences for the translation feature, backed by `UserDefaults`;
/// published properties persist on change (the same shape as
/// `WindowTilingSettings`). The two hotkeys themselves live in
/// `ShortcutSettings` with every other global combo.
@MainActor
final class TranslationSettings: ObservableObject {
    static let shared = TranslationSettings()

    private let defaults: UserDefaults

    /// Whether the two translate hotkeys are registered at all. On by default.
    /// Off makes `HotKeyManager` drop them, so ⌘⇧E/⌘⌥E reach other apps again.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: K.enabled) }
    }

    /// Whether a finished translation is written to the pasteboard. On by
    /// default: that is what makes it land in history and be one ⌘V away.
    @Published var copiesResult: Bool {
        didSet { defaults.set(copiesResult, forKey: K.copiesResult) }
    }

    /// Whether text selected in the focused app is also written to the
    /// pasteboard when a translate shortcut sends it, so the original lands in
    /// the clipboard history next to its translation. On by default.
    @Published var copiesSelection: Bool {
        didSet { defaults.set(copiesSelection, forKey: K.copiesSelection) }
    }

    /// Which CLI the next request goes through.
    @Published var backend: TranslationBackend {
        didSet { defaults.set(backend.rawValue, forKey: K.backend) }
    }

    // Path and model are kept per backend, so switching the picker back and
    // forth never loses what was typed for the other one.

    /// An explicit path to `codex`. Empty means auto-detect — a GUI app does
    /// not inherit the login shell's PATH, so an unusual install location has
    /// to be spelled out here.
    @Published var codexPath: String {
        didSet { defaults.set(codexPath, forKey: K.codexPath) }
    }

    /// Passed to `codex exec -m`. Empty leaves the choice to Codex's own
    /// configuration.
    @Published var codexModel: String {
        didSet { defaults.set(codexModel, forKey: K.codexModel) }
    }

    /// An explicit path to `claude`. Empty means auto-detect.
    @Published var claudePath: String {
        didSet { defaults.set(claudePath, forKey: K.claudePath) }
    }

    /// Passed to `claude --model`. Defaults to `sonnet`; empty leaves the
    /// choice to the CLI.
    @Published var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: K.claudeModel) }
    }

    /// The automatic shortcut's target for each detected source language.
    /// Missing entries fall back to `TranslationSourceLanguage.defaultTarget`.
    @Published var defaultTargets: [TranslationSourceLanguage: TranslationLanguage] {
        didSet {
            for (source, target) in defaultTargets {
                defaults.set(target.rawValue, forKey: K.defaultTargetPrefix + source.rawValue)
            }
        }
    }

    func defaultTarget(for source: TranslationSourceLanguage) -> TranslationLanguage {
        defaultTargets[source] ?? source.defaultTarget
    }

    /// The target the automatic shortcut picks for `text`.
    func defaultTarget(forText text: String) -> TranslationLanguage {
        defaultTarget(for: TranslationSourceLanguage.detect(text))
    }

    /// The result panel's size in points, set in the Translate pane.
    @Published var panelWidth: Double {
        didSet { defaults.set(panelWidth, forKey: K.panelWidth) }
    }

    @Published var panelHeight: Double {
        didSet { defaults.set(panelHeight, forKey: K.panelHeight) }
    }

    /// A colored border around the panel — the same option, defaults and
    /// 0…12 pt range as the clipboard popup's bezel, stored separately so the
    /// two can differ.
    @Published var borderEnabled: Bool {
        didSet { defaults.set(borderEnabled, forKey: K.borderEnabled) }
    }

    @Published var borderColor: Color {
        didSet { defaults.set(borderColor.hexRGBA, forKey: K.borderColor) }
    }

    @Published var borderWidth: Double {
        didSet { defaults.set(borderWidth, forKey: K.borderWidth) }
    }

    nonisolated static let borderWidthRange: ClosedRange<Double> = 0...12

    nonisolated static let panelWidthRange: ClosedRange<Double> = 380...1200
    nonisolated static let panelHeightRange: ClosedRange<Double> = 260...1000
    nonisolated static let defaultPanelSize = (width: 560.0, height: 380.0)

    /// Where the user last dragged the panel (its top-left corner, in screen
    /// coordinates), so it reopens there; nil until it has been moved, which
    /// centres it on the screen holding the mouse.
    var panelTopLeft: NSPoint? {
        get {
            guard let string = defaults.string(forKey: K.panelTopLeft) else { return nil }
            let point = NSPointFromString(string)
            return point == .zero ? nil : point
        }
        set {
            if let newValue { defaults.set(NSStringFromPoint(newValue), forKey: K.panelTopLeft) }
            else { defaults.removeObject(forKey: K.panelTopLeft) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A plain `defaults.bool(forKey:)` cannot express default-on.
        isEnabled = defaults.object(forKey: K.enabled) as? Bool ?? true
        copiesResult = defaults.object(forKey: K.copiesResult) as? Bool ?? true
        copiesSelection = defaults.object(forKey: K.copiesSelection) as? Bool ?? true
        backend = defaults.string(forKey: K.backend).flatMap(TranslationBackend.init(rawValue:)) ?? .codex
        codexPath = defaults.string(forKey: K.codexPath) ?? ""
        codexModel = defaults.string(forKey: K.codexModel) ?? TranslationBackend.codex.defaultModel
        claudePath = defaults.string(forKey: K.claudePath) ?? ""
        claudeModel = defaults.string(forKey: K.claudeModel) ?? TranslationBackend.claude.defaultModel
        var targets: [TranslationSourceLanguage: TranslationLanguage] = [:]
        for source in TranslationSourceLanguage.allCases {
            targets[source] = defaults.string(forKey: K.defaultTargetPrefix + source.rawValue)
                .flatMap(TranslationLanguage.init(rawValue:)) ?? source.defaultTarget
        }
        defaultTargets = targets
        let width = defaults.object(forKey: K.panelWidth) as? Double ?? Self.defaultPanelSize.width
        let height = defaults.object(forKey: K.panelHeight) as? Double ?? Self.defaultPanelSize.height
        borderEnabled = defaults.object(forKey: K.borderEnabled) as? Bool ?? true
        borderColor = defaults.string(forKey: K.borderColor).flatMap(Color.init(hex:))
            ?? ClipboardSettings.defaultPopupBezelColor
        borderWidth = Self.clamp(defaults.object(forKey: K.borderWidth) as? Double ?? 7,
                                 to: Self.borderWidthRange)
        panelWidth = Self.clamp(width, to: Self.panelWidthRange)
        panelHeight = Self.clamp(height, to: Self.panelHeightRange)
    }

    nonisolated static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    func path(for backend: TranslationBackend) -> String {
        switch backend {
        case .codex: return codexPath
        case .claude: return claudePath
        }
    }

    func model(for backend: TranslationBackend) -> String {
        switch backend {
        case .codex: return codexModel
        case .claude: return claudeModel
        }
    }

    func setPath(_ path: String, for backend: TranslationBackend) {
        switch backend {
        case .codex: codexPath = path
        case .claude: claudePath = path
        }
    }

    func setModel(_ model: String, for backend: TranslationBackend) {
        switch backend {
        case .codex: codexModel = model
        case .claude: claudeModel = model
        }
    }

    private enum K {
        static let enabled = "translationEnabled"
        static let copiesResult = "translationCopiesResult"
        static let copiesSelection = "translationCopiesSelection"
        static let backend = "translationBackend"
        static let codexPath = "translationCodexPath"
        static let codexModel = "translationCodexModel"
        static let claudePath = "translationClaudePath"
        static let claudeModel = "translationClaudeModel"
        static let panelWidth = "translationPanelWidth"
        static let panelHeight = "translationPanelHeight"
        static let panelTopLeft = "translationPanelTopLeft"
        static let borderEnabled = "translationBorderEnabled"
        static let borderColor = "translationBorderColor"
        static let borderWidth = "translationBorderWidth"
        static let defaultTargetPrefix = "translationDefaultTarget."
    }
}
