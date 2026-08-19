import SwiftUI

/// The editor's top toolbar: tool palette, color + line-thickness controls, the
/// copy/save actions, and the image-size / zoom status.
struct EditorToolbar: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        HStack(spacing: 8) {
            // Leave room for the window traffic lights (top-left).
            Spacer().frame(width: 64)

            actions
            Divider().frame(height: 22)
            toolPalette
            Divider().frame(height: 22)
            colorPalette
            widthControl
            if showsTextBackgroundToggle { textBackgroundToggle }

            Spacer(minLength: 12)

            sizeReadout
            Divider().frame(height: 22)
            zoomControls
        }
        .buttonStyle(.toolbar)
        .labelStyle(.iconOnly)
        .font(.system(size: 15))
        .padding(.horizontal, 12)
        .frame(height: EditorMetrics.toolbarHeight)
        .background(.bar)
        // Tool buttons shouldn't grab the keyboard focus ring — the active tool is
        // already shown by its filled highlight, and a stray ring on the first
        // button looks broken.
        .focusEffectDisabled()
    }

    // MARK: - Tools

    private var toolPalette: some View {
        HStack(spacing: 2) {
            ForEach(Tool.allCases) { tool in
                Button { viewModel.activeTool = tool } label: {
                    // Label (not bare Image) so VoiceOver gets the tool name; the
                    // toolbar-wide .labelStyle(.iconOnly) keeps it visually an icon.
                    Label(tool.help, systemImage: tool.systemImage)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(viewModel.activeTool == tool
                                      ? Color.accentColor.opacity(0.25) : .clear)
                        )
                }
                .help("\(tool.help) (\(String(EditorShortcuts.effective(tool, CaptureSettings.shared)).uppercased()))")
            }
        }
    }

    // MARK: - Style

    private var colorPalette: some View {
        HStack(spacing: 4) {
            ForEach(Array(AnnotationStyle.palette.enumerated()), id: \.offset) { index, color in
                let name = AnnotationStyle.paletteNames[index]
                Button { viewModel.setColor(color) } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle().strokeBorder(
                                Color.primary.opacity(viewModel.style.color == color ? 0.9 : 0.25),
                                lineWidth: viewModel.style.color == color ? 2 : 1)
                        )
                }
                .help(name)
                .accessibilityLabel(name)
            }
        }
    }

    /// Shown when the text tool is active or a text annotation is selected.
    private var showsTextBackgroundToggle: Bool {
        if viewModel.activeTool == .text { return true }
        if let id = viewModel.selectedID {
            return viewModel.annotations.first(where: { $0.id == id })?.kind == .text
        }
        return false
    }

    private var textBackgroundToggle: some View {
        Button { viewModel.toggleTextBackground() } label: {
            Label("Text background",
                  systemImage: viewModel.style.textBackground
                  ? "character.textbox" : "character")
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(viewModel.style.textBackground
                              ? Color.accentColor.opacity(0.25) : .clear)
                )
        }
        .help("Text background")
    }

    private var widthControl: some View {
        HStack(spacing: 4) {
            if showsTextBackgroundToggle {
                // Text context → the slider sets font size.
                Image(systemName: "textformat.size").foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { viewModel.style.fontSize },
                                   set: { viewModel.setFontSize($0) }),
                    in: 10...96,
                    onEditingChanged: { viewModel.styleSliderEditingChanged($0) }
                )
                .frame(width: 80)
                .help("Text size")
                .accessibilityLabel("Text size")
                ptLabel(viewModel.style.fontSize)
            } else {
                Image(systemName: "lineweight").foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { viewModel.style.lineWidth },
                                   set: { viewModel.setLineWidth($0) }),
                    in: 1...20,
                    onEditingChanged: { viewModel.styleSliderEditingChanged($0) }
                )
                .frame(width: 80)
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

    // MARK: - Actions / status

    private var actions: some View {
        HStack(spacing: 10) {
            if viewModel.cropRect != nil {
                Button("Apply crop", systemImage: "checkmark") { viewModel.applyCrop() }
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Apply crop")

                Button("Cancel crop", systemImage: "xmark") { viewModel.cancelCrop() }
                    .keyboardShortcut(.cancelAction)
                    .help("Cancel crop")

                Divider().frame(height: 22)
            }

            Button("Copy", systemImage: "doc.on.doc") { viewModel.copyToClipboard() }
                .buttonStyle(.toolbarProminent)
                .help("Copy to clipboard (↩ or ⌘C)")

            Button { viewModel.save() } label: {
                FloppyDisk()
                    .fill(Color.primary, style: FillStyle(eoFill: true))
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.toolbarProminent)
            .keyboardShortcut("s", modifiers: .command)
            .accessibilityLabel("Save")
            .help("Save to the configured folder (⌘S)")

            Divider().frame(height: 22)

            Button("Undo", systemImage: "arrow.uturn.backward") { viewModel.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!viewModel.canUndo)
                .help("Undo (⌘Z)")

            Button("Redo", systemImage: "arrow.uturn.forward") { viewModel.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!viewModel.canRedo)
                .help("Redo (⇧⌘Z)")
        }
    }

    private var sizeReadout: some View {
        let s = viewModel.logicalSize
        return VStack(alignment: .trailing, spacing: 0) {
            Text("\(Int(s.width.rounded())) × \(Int(s.height.rounded()))pt")
                .font(.system(size: 12, weight: .medium))
            Text("Image size").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            // Multiplicative steps so each click changes the zoom proportionally —
            // additive ±0.1 doubled the zoom at 10% and was imperceptible at 800%.
            Button("Zoom out", systemImage: "minus") { stepZoom(by: 1 / 1.25) }
                .help("Zoom out")
            Text("\(Int((viewModel.zoom * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .frame(width: 42)
            Button("Zoom in", systemImage: "plus") { stepZoom(by: 1.25) }
                .help("Zoom in")
            Button("Fit and center", systemImage: "arrow.up.left.and.arrow.down.right") {
                // Grow the window a bit for breathing room, then refit & center.
                EditorWindowController.growAndCenterKeyWindow(by: 100)
                Task { viewModel.fitAndCenter() }
            }
            .help("Fit & center (enlarges the window)")
        }
        .font(.system(size: 11))
    }

    private func stepZoom(by factor: CGFloat) {
        viewModel.zoom = min(8, max(0.1, viewModel.zoom * factor))
        viewModel.hasUserZoomed = true
    }
}
