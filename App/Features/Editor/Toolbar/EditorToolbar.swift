import SwiftUI

/// The editor's toolbar, in two rows.
///
/// It used to be one flat `HStack` in a 44 pt bar holding the traffic-light gap,
/// four actions, thirteen undifferentiated tool tiles, eight swatches, a slider,
/// a two-line readout and four zoom controls — wide enough that the window had a
/// 1080 pt minimum width purely to keep it visible. Splitting it separates
/// *window chrome* (undo/zoom/size/copy/save) from *the work* (tools + style), and
/// lets the style controls be contextual instead of always-on.
struct EditorToolbar: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            chromeRow
            workRow
        }
        .buttonStyle(.toolbar)
        .background(.bar)
        // Tool buttons shouldn't grab the keyboard focus ring — the active tool is
        // already shown by its filled highlight, and a stray ring on the first
        // button looks broken.
        .focusEffectDisabled()
    }

    // MARK: - Row 1: window chrome

    private var chromeRow: some View {
        HStack(spacing: 10) {
            // Leave room for the window traffic lights (top-left).
            Spacer().frame(width: EditorMetrics.trafficLightGap)

            primaryActions
            separator
            historyControls
            separator
            zoomControls
            separator
            sizeReadout

            Spacer(minLength: 12)
        }
        .labelStyle(.iconOnly)
        // No leading padding: `trafficLightGap` already reserves the space, and
        // Copy/Save lead the row — every extra point here pushes them off the edge.
        .padding(.trailing, 12)
        .frame(height: EditorMetrics.chromeRowHeight)
    }

    private var historyControls: some View {
        HStack(spacing: 2) {
            ToolTile(systemImage: "arrow.uturn.backward", help: "Undo (⌘Z)") {
                viewModel.undo()
            }
            .disabled(!viewModel.canUndo)

            ToolTile(systemImage: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") {
                viewModel.redo()
            }
            .disabled(!viewModel.canRedo)
        }
        // ⌘Z / ⇧⌘Z are handled in `EditorView.handleKey`, not as key equivalents
        // here: a button's key equivalent fires even while an inline text field has
        // focus, so ⌘Z mid-typing used to undo the whole editor state.
        .font(.system(size: 13))
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            // Multiplicative steps so each click changes the zoom proportionally —
            // additive ±0.1 doubled the zoom at 10% and was imperceptible at 800%.
            ToolTile(systemImage: "minus", help: "Zoom out") { stepZoom(by: 1 / 1.25) }
            Text("\(Int((viewModel.zoom * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42)
            ToolTile(systemImage: "plus", help: "Zoom in") { stepZoom(by: 1.25) }
            ToolTile(systemImage: "arrow.up.left.and.arrow.down.right",
                     help: "Fit & center (enlarges the window)") {
                // Grow the window a bit for breathing room, then refit & center.
                EditorWindowController.growAndCenterKeyWindow(by: 100)
                Task { viewModel.fitAndCenter() }
            }
        }
        .font(.system(size: 12))
    }

    private var sizeReadout: some View {
        let s = viewModel.logicalSize
        return Text("\(Int(s.width.rounded())) × \(Int(s.height.rounded())) pt")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .help("Image size")
            .accessibilityLabel("Image size")
    }

    /// Copy and Save carry their labels (and a resting accent tint from
    /// `.toolbarProminent`) so the primary actions don't look like every other
    /// icon in the bar. They lead the row, right after the traffic-light gap.
    private var primaryActions: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.copyToClipboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.toolbarProminent)
            .help("Copy to clipboard (↩ or ⌘C)")

            Button {
                viewModel.save()
            } label: {
                HStack(spacing: 5) {
                    FloppyDisk()
                        // Explicit white: a filled `Shape` ignores the style's
                        // `foregroundStyle`, and `Color.primary` goes black on the
                        // accent capsule.
                        .fill(Color.white, style: FillStyle(eoFill: true))
                        .frame(width: 13, height: 13)
                    Text("Save").font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.toolbarProminent)
            .keyboardShortcut("s", modifiers: .command)
            .accessibilityLabel("Save")
            .help("Save to the configured folder (⌘S)")
        }
    }

    // MARK: - Row 2: tools and style

    private var workRow: some View {
        HStack(spacing: 8) {
            toolPalette

            Spacer(minLength: 12)

            // Crop takes over the style controls' trailing slot while it's armed,
            // so arming it swaps one trailing cluster for another instead of
            // adding a third and reflowing the row.
            if viewModel.cropRect != nil {
                cropActions
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if showsStyleControls {
                styleControls
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 15))
        .padding(.horizontal, 12)
        .frame(height: EditorMetrics.workRowHeight)
        .animation(.easeInOut(duration: 0.15), value: viewModel.activeTool)
        .animation(.easeInOut(duration: 0.15), value: viewModel.cropRect != nil)
        .animation(.easeInOut(duration: 0.15), value: showsTextControls)
    }

    /// The 13 tools, rendered as related clusters (`Tool.groups`) inside soft
    /// containers rather than one undifferentiated run.
    private var toolPalette: some View {
        HStack(spacing: 6) {
            ForEach(Array(Tool.groups.enumerated()), id: \.offset) { _, group in
                HStack(spacing: 1) {
                    ForEach(group) { tool in
                        ToolTile(systemImage: tool.systemImage,
                                 isOn: viewModel.activeTool == tool,
                                 help: toolHelp(tool)) {
                            viewModel.activeTool = tool
                        }
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: EditorMetrics.tileCorner + 2)
                        .fill(Color.primary.opacity(0.05))
                )
            }
        }
    }

    private func toolHelp(_ tool: Tool) -> String {
        let key = String(EditorShortcuts.effective(tool, CaptureSettings.shared)).uppercased()
        return "\(tool.help) (\(key))"
    }

    // MARK: - Contextual style controls

    /// True when the text tool is active or a text annotation is selected — the
    /// context in which the width slider means *font size* and the background
    /// toggle applies.
    private var showsTextControls: Bool {
        if viewModel.activeTool == .text { return true }
        if let id = viewModel.selectedID {
            return viewModel.annotations.first(where: { $0.id == id })?.kind == .text
        }
        return false
    }

    /// Style only applies to tools that draw something. `select`, `hand` and
    /// `crop` hide it entirely — unless an annotation is selected, whose style the
    /// controls then edit.
    private var showsStyleControls: Bool {
        viewModel.activeTool.annotationKind != nil || viewModel.selectedID != nil
    }

    private var styleControls: some View {
        HStack(spacing: 8) {
            ColorSwatchRow(selectedIndex: AnnotationStyle.palette
                            .firstIndex(of: viewModel.style.color)) { _, color in
                viewModel.setColor(color)
            }

            separator
            widthControl

            if showsTextControls { textBackgroundToggle }
        }
    }

    private var textBackgroundToggle: some View {
        ToolTile(isOn: viewModel.style.textBackground, help: "Text background") {
            viewModel.toggleTextBackground()
        } content: {
            Image(systemName: viewModel.style.textBackground
                  ? "character.textbox" : "character")
        }
    }

    /// One slider that swaps meaning with the context: font size for text,
    /// stroke thickness otherwise.
    private var widthControl: some View {
        HStack(spacing: 6) {
            if showsTextControls {
                Image(systemName: "textformat.size")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { viewModel.style.fontSize },
                                   set: { viewModel.setFontSize($0) }),
                    in: 10...96,
                    onEditingChanged: { viewModel.styleSliderEditingChanged($0) }
                )
                .controlSize(.small)
                .frame(width: 110)
                .help("Text size")
                .accessibilityLabel("Text size")
                ptLabel(viewModel.style.fontSize)
            } else {
                Image(systemName: "lineweight")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { viewModel.style.lineWidth },
                                   set: { viewModel.setLineWidth($0) }),
                    in: 1...20,
                    onEditingChanged: { viewModel.styleSliderEditingChanged($0) }
                )
                .controlSize(.small)
                .frame(width: 110)
                .help("Line thickness")
                .accessibilityLabel("Line thickness")
                ptLabel(viewModel.style.lineWidth)
            }
        }
    }

    /// A fixed-width "N pt" readout for the width/size slider.
    private func ptLabel(_ value: Double) -> some View {
        Text("\(Int(value.rounded())) pt")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 34, alignment: .leading)
    }

    // MARK: - Crop

    private var cropActions: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.applyCrop()
            } label: {
                Label("Apply crop", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.toolbarProminent)
            .keyboardShortcut(.return, modifiers: [])
            .help("Apply crop (↩)")

            ToolTile(systemImage: "xmark", help: "Cancel crop (esc)") {
                viewModel.cancelCrop()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Bits

    private var separator: some View {
        Divider().frame(height: 18)
    }

    private func stepZoom(by factor: CGFloat) {
        viewModel.zoom = min(8, max(0.1, viewModel.zoom * factor))
        viewModel.hasUserZoomed = true
    }
}
