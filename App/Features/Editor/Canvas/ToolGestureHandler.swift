import AppKit
import SwiftUI

/// Transparent interaction layer sized to the (possibly grown) canvas, sitting
/// above the `FlatCanvas`. It turns drags into annotation creation / selection
/// moves / handle resizes, draws the (non-exported) selection box and handles,
/// and hosts the inline text editor.
///
/// Coordinates: the layer's local origin sits at `contentBounds.origin` in image
/// space (negative once annotations spill past an edge), so gesture points are
/// shifted back to image coordinates by adding that origin, and overlays drawn
/// in image coordinates are shifted by subtracting it.
struct ToolGestureHandler: View {
    @ObservedObject var viewModel: EditorViewModel
    /// The full interactive area (workspace = content + drawable margin).
    let bounds: CGRect
    /// Visual-only pan callbacks for the hand tool (translation in screen points).
    var onPan: (CGSize) -> Void = { _ in }
    var onPanEnded: () -> Void = {}

    private var origin: CGPoint { bounds.origin }

    var body: some View {
        ZStack(alignment: .topLeading) {
            interactionLayer

            selectionOverlay
            cropOverlay
            textEditor
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
    }

    @ViewBuilder
    private var interactionLayer: some View {
        let rect = Rectangle().fill(.clear).contentShape(Rectangle())
        if viewModel.activeTool == .hand {
            rect.gesture(panDrag)
        } else {
            rect.gesture(drag)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { viewModel.dragChanged(start: $0.startLocation + origin, current: $0.location + origin) }
            .onEnded { viewModel.dragEnded(start: $0.startLocation + origin, current: $0.location + origin) }
    }

    /// Hand-tool pan: global coordinates stay stable even as the panned content
    /// (which hosts this view) shifts, so the translation can't feed back.
    private var panDrag: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { onPan($0.translation) }
            .onEnded { _ in onPanEnded() }
    }

    /// Dashed bounding box plus draggable resize handles for the selection.
    @ViewBuilder
    private var selectionOverlay: some View {
        if viewModel.editingTextID == nil,
           let id = viewModel.selectedID,
           let a = viewModel.annotations.first(where: { $0.id == id }) {
            let invZoom = 1 / max(viewModel.zoom, 0.0001)
            let handleSize = 8 * invZoom
            Canvas { ctx, _ in
                ctx.translateBy(x: -origin.x, y: -origin.y)
                let box = a.boundingBox.insetBy(dx: -4, dy: -4)
                ctx.stroke(Path(box), with: .color(.accentColor),
                           style: StrokeStyle(lineWidth: invZoom, dash: [4, 3]))
                for pos in viewModel.handlePositions(of: a).values {
                    let r = CGRect(x: pos.x - handleSize / 2, y: pos.y - handleSize / 2,
                                   width: handleSize, height: handleSize)
                    let shape = Path(roundedRect: r, cornerRadius: handleSize * 0.25)
                    ctx.fill(shape, with: .color(.white))
                    ctx.stroke(shape, with: .color(.accentColor), lineWidth: invZoom)
                }
            }
            .frame(width: bounds.width, height: bounds.height)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var cropOverlay: some View {
        if let rect = viewModel.cropRect {
            Canvas { ctx, size in
                ctx.translateBy(x: -origin.x, y: -origin.y)
                // Dim everything, then punch out the crop rect via even-odd fill.
                var dimmed = Path(CGRect(origin: origin, size: size))
                dimmed.addRect(rect)
                ctx.fill(dimmed, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
                ctx.stroke(Path(rect), with: .color(.white), style: StrokeStyle(lineWidth: 1))
            }
            .frame(width: bounds.width, height: bounds.height)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var textEditor: some View {
        if let id = viewModel.editingTextID,
           let a = viewModel.annotations.first(where: { $0.id == id }) {
            let hasBg = a.style.textBackground
            // AppKit-backed field that makes itself first responder on appear, so a
            // single click with the text tool drops straight into typing (SwiftUI's
            // @FocusState is unreliable for fields hosted in our custom NSWindow).
            InlineTextField(text: viewModel.textBinding(for: id),
                            fontSize: a.style.fontSize,
                            color: NSColor(hasBg ? a.style.textColor : a.style.color),
                            onCommit: { viewModel.editingTextID = nil })
                .fixedSize()
                .padding(.horizontal, hasBg ? 8 : 0)
                .padding(.vertical, hasBg ? 4 : 0)
                .background(hasBg ? a.style.color : .clear, in: RoundedRectangle(cornerRadius: 6))
                .offset(x: a.rect.minX - origin.x - (hasBg ? 8 : 0),
                        y: a.rect.minY - origin.y - (hasBg ? 4 : 0))
        }
    }
}

/// A borderless, transparent single-line text field that makes itself the window's
/// first responder the moment it appears, so a single click with the text tool
/// lets you type immediately. SwiftUI's `@FocusState` is unreliable for fields
/// hosted in our custom `NSWindow`, hence the AppKit backing.
private struct InlineTextField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var color: NSColor
    var onCommit: () -> Void

    func makeNSView(context: Context) -> GrowingTextField {
        let field = GrowingTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.cell?.isScrollable = false   // grow (via intrinsic size) instead of scroll
        field.cell?.wraps = false
        return field
    }

    func updateNSView(_ field: GrowingTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit
        if field.stringValue != text { field.stringValue = text }
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = color
        field.invalidateIntrinsicContentSize()
        // Focus once, on the next main-actor turn when the field is in a window.
        if !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            Task { @MainActor in
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>?
        var onCommit: (() -> Void)?
        var didFocus = false

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text?.wrappedValue = field.stringValue
            field.invalidateIntrinsicContentSize()   // grow as you type
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            // Return commits; Escape also ends the editing session (the text typed
            // so far is kept — the session's undo step can revert it).
            if selector == #selector(NSResponder.insertNewline(_:))
                || selector == #selector(NSResponder.cancelOperation(_:)) {
                onCommit?()
                return true
            }
            return false
        }
    }
}

/// An `NSTextField` whose intrinsic width tracks its current text, so the SwiftUI
/// wrapper (`.fixedSize()`) grows it as you type.
final class GrowingTextField: NSTextField {
    override var intrinsicContentSize: NSSize {
        let string = stringValue.isEmpty ? (placeholderString ?? " ") : stringValue
        let measured = (string as NSString).size(
            withAttributes: [.font: font ?? .systemFont(ofSize: NSFont.systemFontSize)])
        return NSSize(width: ceil(measured.width) + 8,        // caret + trailing room
                      height: ceil(max(measured.height, super.intrinsicContentSize.height)))
    }
}
