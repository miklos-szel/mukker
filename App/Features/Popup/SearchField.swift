import AppKit
import SwiftUI

/// AppKit-backed search field so we can intercept arrow keys + Enter cleanly.
/// Styled for the popup search row: borderless text with a magnifying-glass icon.
struct PopupSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Search"
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onBackspaceAtStart: (() -> Void)? = nil
    var onMoveLeft: (() -> Void)? = nil
    var onMoveRight: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSTextField {
        let field = BorderlessSearchTextField()
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: PopupTheme.searchPlaceholderColor,
                .font: NSFont.systemFont(ofSize: 18, weight: .regular)
            ]
        )
        field.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        field.textColor = PopupTheme.searchTextColor
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.fieldChanged(_:))
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: PopupTheme.searchPlaceholderColor,
                .font: NSFont.systemFont(ofSize: 18, weight: .regular)
            ]
        )
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PopupSearchField
        init(parent: PopupSearchField) { self.parent = parent }

        @objc func fieldChanged(_ sender: NSTextField) {
            parent.text = sender.stringValue
        }

        /// Live update on every keystroke — NSTextField's target/action only
        /// fires on Enter/end-editing, so this is what actually drives search.
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp(); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown(); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel(); return true
            case #selector(NSResponder.deleteBackward(_:)):
                if textView.selectedRange().location == 0,
                   textView.string.isEmpty {
                    parent.onBackspaceAtStart?()
                    return true
                }
                return false
            case #selector(NSResponder.moveLeft(_:)):
                if textView.selectedRange().location == 0,
                   let onLeft = parent.onMoveLeft {
                    onLeft(); return true
                }
                return false
            case #selector(NSResponder.moveRight(_:)):
                // NSRange offsets are UTF-16; compare against NSString length,
                // not Character count (they diverge for emoji etc.).
                if let onRight = parent.onMoveRight,
                   textView.selectedRange().location == (textView.string as NSString).length {
                    onRight(); return true
                }
                return false
            default:
                return false
            }
        }
    }
}

private final class BorderlessSearchTextField: NSTextField {
    override var allowsVibrancy: Bool { false }
}
