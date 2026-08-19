import AppKit
import SwiftUI

/// A light/grey transparency checkerboard, like image editors show behind
/// transparent pixels. Drawn once into a tiled-friendly Canvas.
private struct Checkerboard: View {
    var square: CGFloat = 8

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let cols = Int(ceil(size.width / square))
            let rows = Int(ceil(size.height / square))
            var dark = Path()
            for r in 0..<max(rows, 0) {
                for c in 0..<max(cols, 0) where (r + c) % 2 == 1 {
                    dark.addRect(CGRect(x: CGFloat(c) * square, y: CGFloat(r) * square,
                                        width: square, height: square))
                }
            }
            ctx.fill(dark, with: .color(Color(white: 0.85)))
        }
        .drawingGroup()
    }
}

/// Root editor UI: a toolbar across the top and a zoomable canvas below.
struct EditorView: View {
    @ObservedObject var viewModel: EditorViewModel
    @FocusState private var canvasFocused: Bool
    /// Visual-only pan offset for the hand tool (never affects the exported image).
    @State private var viewPan: CGSize = .zero
    @State private var panStart: CGSize?

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(viewModel: viewModel)
            Divider()
            canvas
        }
        .background(WheelZoomCatcher { deltaY in
            let factor: CGFloat = deltaY > 0 ? 1.1 : 1 / 1.1
            viewModel.zoom = min(8, max(0.1, viewModel.zoom * factor))
            viewModel.hasUserZoomed = true
        })
        .overlay(alignment: .bottom) { statusHUD }
        .animation(.easeInOut(duration: 0.2), value: viewModel.statusMessage)
        // Min width keeps the whole toolbar visible even when resized down.
        .frame(minWidth: EditorMetrics.minWindowWidth, minHeight: EditorMetrics.minWindowHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        // Key handling lives at the root so it catches shortcuts regardless of which
        // child holds focus (a focused TextField still consumes its own typing, so
        // editing text isn't hijacked). Initial focus goes here, not a toolbar
        // button, so there's no stray focus ring. Active tool = filled highlight.
        .focusable()
        .focused($canvasFocused)
        .focusEffectDisabled()
        .defaultFocus($canvasFocused, true)
        .onAppear { canvasFocused = true }
        .onChange(of: viewModel.editingTextID) { _, newValue in
            // Hand focus to the inline text field while editing; take it back after.
            canvasFocused = (newValue == nil)
        }
        .onDeleteCommand { viewModel.deleteSelected() }
        .onKeyPress(action: handleKey)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let zoom = viewModel.zoom
            // `layout` (committed annotations only) drives the matte/gesture/scroll
            // geometry so it's stable during a drag; `draw` (draft-inclusive) drives
            // FlatCanvas so the in-progress shape renders unclipped.
            let layout = viewModel.layoutBounds
            let draw = viewModel.contentBounds
            let work = workspace(around: layout, viewport: proxy.size, zoom: zoom)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    // The single, unscaled checkerboard backdrop (below) shows
                    // through the transparent surround; the white content region
                    // (FlatCanvas) shows exactly what will export.
                    FlatCanvas(baseImage: viewModel.baseImage,
                               imageSize: viewModel.logicalSize,
                               contentBounds: draw,
                               imageOrigin: viewModel.imageOrigin,
                               annotations: viewModel.displayAnnotations)
                        .offset(x: draw.minX - work.minX, y: draw.minY - work.minY)
                    // The hand tool's pan is handled inside ToolGestureHandler (which
                    // reliably receives canvas drags); it reports translation here and
                    // we apply it as a visual-only offset.
                    ToolGestureHandler(viewModel: viewModel, bounds: work,
                                       onPan: { translation in
                                           let base = panStart ?? viewPan
                                           if panStart == nil { panStart = base }
                                           viewPan = CGSize(width: base.width + translation.width,
                                                            height: base.height + translation.height)
                                       },
                                       onPanEnded: { panStart = nil })
                }
                .frame(width: work.width, height: work.height, alignment: .topLeading)
                // Scale from the center: `scaleEffect` keeps the pre-scale layout size
                // (`work`), so the following fixed-size frame must center the scaled
                // content to avoid a top-left bias of `work·(1−zoom)/2`. A top-leading
                // anchor here would shift the capture off-center by that amount.
                .scaleEffect(zoom, anchor: .center)
                .frame(width: work.width * zoom, height: work.height * zoom)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height,
                       alignment: .center)
                .offset(viewPan)
            }
            .scrollIndicators(.visible)
            .background(Checkerboard())
            .onAppear { fitToWindow(proxy.size) }
            .onChange(of: proxy.size) { _, newSize in fitToWindow(newSize) }
        }
    }

    /// The interactive workspace rect (in image points), centred on `content` and
    /// expanded toward a small draw-margin but capped to the viewport so the
    /// surrounding white space never forces a scrollbar — keeping the image
    /// centred with symmetric matte around it.
    private func workspace(around content: CGRect, viewport: CGSize, zoom: CGFloat) -> CGRect {
        let margin: CGFloat = 120
        let vpW = viewport.width / max(zoom, 0.0001)
        let vpH = viewport.height / max(zoom, 0.0001)
        let w = max(content.width, min(content.width + margin * 2, vpW))
        let h = max(content.height, min(content.height + margin * 2, vpH))
        return CGRect(x: content.midX - w / 2, y: content.midY - h / 2, width: w, height: h)
    }

    /// Keeps the capture fitted to the viewport (with margin) on open and on resize,
    /// until the user takes manual zoom control. This avoids the stale one-shot fit
    /// that left the capture tiny and off-center when the window grew after the first
    /// (too-small) layout pass. Also syncs the viewport size for the fit/center action.
    private func fitToWindow(_ viewport: CGSize) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        viewModel.viewportSize = viewport
        guard !viewModel.hasUserZoomed else { return }
        viewModel.zoom = viewModel.fitZoom(in: viewport)
    }

    /// Handles editor keyboard shortcuts. Returns `.ignored` while a text
    /// annotation is being edited so every keystroke goes to the inline field —
    /// typing a tool letter inserts the character instead of switching tools.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard viewModel.editingTextID == nil else { return .ignored }
        // ⌘, opens Settings even while an editor window is key.
        if press.modifiers == .command, press.characters == "," {
            (NSApp.delegate as? AppDelegate)?.openSettings()
            return .handled
        }
        // Standard window shortcuts — as an LSUIElement app there may be no main
        // menu supplying these key equivalents, so handle them here.
        if press.modifiers == .command, press.characters == "c" {
            viewModel.copyToClipboard()
            return .handled
        }
        if press.modifiers == .command, press.characters == "w" {
            viewModel.requestClose?()
            return .handled
        }
        if press.modifiers.isEmpty {
            if press.key == .return {
                // While a crop is pending, Return applies it (matches the toolbar's
                // ↩-bound Apply button) instead of copying.
                if viewModel.cropRect != nil {
                    viewModel.applyCrop()
                } else {
                    viewModel.copyToClipboard()
                }
                return .handled
            }
            if press.key == .escape {
                switch viewModel.escapeAction(escCopiesAndCloses: CaptureSettings.shared.escCopiesAndCloses) {
                case .cancelCrop:
                    viewModel.cancelCrop()
                case .deselect:
                    viewModel.deselect()
                case .copyAndClose:
                    // Esc as "done": copy and close regardless of `closeAfterCopy`.
                    viewModel.copyToClipboard()
                    viewModel.requestClose?()
                }
                return .handled
            }
            if let char = press.characters.first,
               let tool = EditorShortcuts.tool(forKey: char, CaptureSettings.shared) {
                viewModel.activeTool = tool
                return .handled
            }
        }
        return .ignored
    }

    /// Installs a window-scoped scroll-wheel monitor that turns plain mouse-wheel
    /// scrolls into zoom. Precise (trackpad) scrolls pass through so two-finger
    /// panning still works; scrolls over the toolbar are left alone.
    private struct WheelZoomCatcher: NSViewRepresentable {
        let onZoom: (CGFloat) -> Void

        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ nsView: NSView, context: Context) {
            context.coordinator.window = nsView.window
            context.coordinator.onZoom = onZoom
            context.coordinator.installIfNeeded()
        }
        func makeCoordinator() -> Coordinator { Coordinator() }
        static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

        final class Coordinator {
            weak var window: NSWindow?
            var onZoom: ((CGFloat) -> Void)?
            private var token: Any?

            func installIfNeeded() {
                guard token == nil else { return }
                token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let win = self.window, event.window === win,
                          !event.hasPreciseScrollingDeltas, event.scrollingDeltaY != 0
                    else { return event }
                    if let content = win.contentView {
                        let p = content.convert(event.locationInWindow, from: nil)
                        let yFromTop = content.isFlipped ? p.y : content.bounds.height - p.y
                        if yFromTop < EditorMetrics.toolbarHeight { return event }   // over the toolbar
                    }
                    self.onZoom?(event.scrollingDeltaY)
                    return nil
                }
            }

            func remove() {
                if let token { NSEvent.removeMonitor(token) }
                token = nil
            }
            deinit { remove() }
        }
    }

    /// Transient confirmation HUD (e.g. after Copy / Save).
    @ViewBuilder
    private var statusHUD: some View {
        if let message = viewModel.statusMessage {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.75), in: Capsule())
                .padding(.bottom, 24)
                .transition(.opacity)
        }
    }
}
