import Foundation

/// The one rule for user-entered snippet and collection names, shared by the
/// popup's "add to snippets" prompt and the Snippets Manager so the two can't
/// disagree about what a valid name is.
enum SnippetNaming {
    /// Longest name either place stores. Long enough for any real title, short
    /// enough that a pasted paragraph doesn't become one.
    static let maxLength = 100

    /// Length of a name derived from a clip's first line.
    static let derivedLength = 50

    /// `input` trimmed and capped at `maxLength`; an empty or whitespace-only
    /// entry yields `fallback` (itself trimmed and capped) instead.
    static func normalized(_ input: String, fallback: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = trimmed.isEmpty
            ? fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
        return String(chosen.prefix(maxLength))
    }

    /// `input` trimmed and capped, or nil when nothing is left — for renames,
    /// where an empty entry keeps the previous name.
    static func validated(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxLength))
    }

    /// A snippet name derived from the first non-blank line of `text`,
    /// truncated to `derivedLength`; "Snippet" when there is none.
    static func defaultName(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return firstLine.isEmpty ? "Snippet" : String(firstLine.prefix(derivedLength))
    }
}
