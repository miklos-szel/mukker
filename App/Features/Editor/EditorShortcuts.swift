import Foundation

/// Resolves editor tool keys against user overrides in `CaptureSettings`.
/// Lives in the Editor (Features) layer because it bridges the `Tool` type with
/// the raw-string override map persisted by `CaptureSettings` (Core).
enum EditorShortcuts {
    /// The effective shortcut for a tool: the user's override, else the default.
    @MainActor
    static func effective(_ tool: Tool, _ settings: CaptureSettings) -> Character {
        settings.toolShortcuts[tool.rawValue]?.first ?? tool.shortcut
    }

    /// The tool a key currently selects, honoring overrides. Nil if unbound.
    @MainActor
    static func tool(forKey char: Character, _ settings: CaptureSettings) -> Tool? {
        Tool.allCases.first { effective($0, settings) == char }
    }

    /// Binds `char` to `tool`. If another tool already uses `char`, the two swap
    /// keys so every tool keeps a unique, non-empty binding.
    @MainActor
    static func assign(_ char: Character, to tool: Tool, _ settings: CaptureSettings) {
        guard let normalized = normalize(char) else { return }
        var map = settings.toolShortcuts
        let previous = effective(tool, settings)
        if let holder = self.tool(forKey: normalized, settings), holder != tool {
            map[holder.rawValue] = String(previous)
        }
        map[tool.rawValue] = String(normalized)
        settings.toolShortcuts = map
    }

    /// A valid tool key is a single ASCII letter, stored lowercase.
    static func normalize(_ char: Character) -> Character? {
        guard let lower = char.lowercased().first, lower.isLetter, lower.isASCII else { return nil }
        return lower
    }
}
