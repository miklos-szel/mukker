import AppKit
import SwiftUI

/// Read-only rich-text preview: loads an RTF file into a non-editable, scrollable
/// NSTextView so formatting (bold, links, colors) renders faithfully.
struct RichTextView: NSViewRepresentable {
    let rtfPath: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        // Rich clips carry their own colors (typically dark text), so always
        // render on the light backdrop under a forced light appearance —
        // otherwise dark mode shows black-on-dark text.
        scroll.appearance = NSAppearance(named: .aqua)
        scroll.drawsBackground = true
        scroll.backgroundColor = PopupTheme.richTextBackdrop
        scroll.borderType = .noBorder

        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // SwiftUI calls this on every update; only re-read the file when the
        // path actually changed (paths are content-addressed, so same path
        // means same content).
        guard context.coordinator.loadedPath != rtfPath else { return }
        context.coordinator.loadedPath = rtfPath
        let attr = (try? NSAttributedString(
            url: URL(fileURLWithPath: rtfPath),
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil))
            ?? NSAttributedString(string: "")
        textView.textStorage?.setAttributedString(attr)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedPath: String?
    }
}
