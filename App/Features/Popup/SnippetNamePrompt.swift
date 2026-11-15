import AppKit

/// Native prompts for the preview pane's "add to snippets" star. The popup is a
/// borderless non-activating panel, so a modal `NSAlert` is more reliable than
/// a SwiftUI sheet. While an alert is modal the popup stays open
/// (`PopupWindowController` ignores focus changes during a modal session), and
/// afterwards key focus is handed back to whichever window had it — the popup —
/// so the flow ends on the same row it started from.
@MainActor
enum SnippetNamePrompt {
    /// Asks for the name of a snippet being added to `collectionName`, prefilled
    /// with `suggested` (selected, so Return accepts it). Nil on Cancel.
    static func askSnippetName(collectionName: String, suggested: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Add to “\(collectionName)”"
        alert.informativeText = "Name the new snippet."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = makeField(value: suggested, placeholder: "Snippet name")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard run(alert) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Asks for a new collection's name (empty, focused) and the snippet's name
    /// (prefilled). "Create" stays disabled until the collection name has
    /// something other than whitespace in it. Nil on Cancel.
    static func askNewCollection(suggestedSnippetName: String) -> (collection: String, snippet: String)? {
        let alert = NSAlert()
        alert.messageText = "New Collection"
        alert.informativeText = "Name the collection and the snippet to add to it."
        let create = alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let collectionField = makeField(value: "", placeholder: "Collection name")
        let snippetField = makeField(value: suggestedSnippetName, placeholder: "Snippet name")
        let grid = NSGridView(views: [
            [label("Collection:"), collectionField],
            [label("Snippet:"), snippetField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        collectionField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        snippetField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid

        let validator = NonEmptyValidator(button: create)
        collectionField.delegate = validator
        create.isEnabled = false
        alert.window.initialFirstResponder = collectionField
        collectionField.nextKeyView = snippetField
        snippetField.nextKeyView = collectionField

        let response = withExtendedLifetime(validator) { run(alert) }
        guard response == .alertFirstButtonReturn,
              SnippetNaming.validated(collectionField.stringValue) != nil else { return nil }
        return (collectionField.stringValue, snippetField.stringValue)
    }

    /// Reports a failed add instead of swallowing it in the log.
    static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't add the snippet"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = run(alert)
    }

    /// Runs `alert` modally over the popup, then returns key focus to the
    /// window that had it before.
    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let previousKey = NSApp.keyWindow
        NSApp.activate()
        let response = alert.runModal()
        if let previousKey, previousKey.isVisible { previousKey.makeKey() }
        return response
    }

    private static func makeField(value: String, placeholder: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        return field
    }

    private static func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    /// Enables `button` only while the observed field holds a usable name.
    private final class NonEmptyValidator: NSObject, NSTextFieldDelegate {
        weak var button: NSButton?

        init(button: NSButton) {
            self.button = button
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            button?.isEnabled = SnippetNaming.validated(field.stringValue) != nil
        }
    }
}
