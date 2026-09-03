import AppKit
import SwiftUI

/// State for one editor window: the captured image plus (later) annotations,
/// the active tool, current style, selection and zoom.
@MainActor
final class EditorViewModel: ObservableObject {
    /// The base (captured/cropped/resized) image in pixels.
    @Published var baseImage: CGImage { didSet { baseNSImage = ImageExporter.nsImage(from: baseImage) } }
    /// `baseImage` wrapped for SwiftUI, rebuilt only when the image itself changes.
    /// `FlatCanvas` renders on every drag frame, and building this inside its body
    /// allocated a new `NSImage` each time — defeating SwiftUI's image caching and
    /// forcing a full-resolution resample per frame.
    @Published private(set) var baseNSImage: NSImage
    @Published var zoom: CGFloat = 1.0

    /// Most recent canvas viewport size in points, kept in sync by the view so the
    /// toolbar's fit/center action can recompute the fitting zoom.
    var viewportSize: CGSize = .zero

    /// True once the user changes zoom manually (wheel / zoom buttons). While false,
    /// the view keeps the capture auto-fitted to the viewport on open and resize.
    var hasUserZoomed = false

    /// Transient confirmation message (e.g. "Copied to clipboard") shown as a HUD,
    /// auto-cleared shortly after it's set.
    @Published var statusMessage: String?
    private var statusClearTask: Task<Void, Never>?

    /// Pixels-per-point of the source capture, so we can show logical sizes.
    let sourceScale: CGFloat

    /// Transparent margin (logical points) reserved around the capture by `fitZoom`
    /// when the editor opens — purely presentational, never exported.
    let canvasPadding: CGFloat

    /// Closes the editor window hosting this model. Wired by `EditorWindowController`;
    /// invoked after copy/save when the matching auto-close setting is on.
    var requestClose: (() -> Void)?

    @Published var annotations: [Annotation] = []
    /// Top-left of the base image in canvas (logical) points. The select/pointer
    /// tool can drag the captured image around the white canvas; defaults to origin.
    @Published var imageOrigin: CGPoint = .zero
    /// Selecting an annotation loads its style into the toolbar, so the sliders
    /// and swatches show (and edit) the selection's real values rather than
    /// silently overwriting them with stale toolbar state.
    @Published var selectedID: Annotation.ID? {
        didSet {
            guard oldValue != selectedID, let id = selectedID,
                  let a = annotations.first(where: { $0.id == id }) else { return }
            style = a.style
        }
    }
    @Published var activeTool: Tool = .arrow {
        didSet { if activeTool != .crop { cropRect = nil } }
    }
    @Published var style = AnnotationStyle()

    /// Pending crop region in logical points, shown while the crop tool is armed
    /// and awaiting Apply/Cancel. Nil when not cropping.
    @Published var cropRect: CGRect?

    /// The annotation being drawn during a drag; committed to `annotations` on release.
    @Published var draft: Annotation?
    /// The text annotation currently open for inline editing, if any. Opening a
    /// session snapshots state; closing it records one undo step for the edit.
    @Published var editingTextID: Annotation.ID? {
        didSet {
            guard !isApplyingHistory else { return }
            if oldValue == nil, editingTextID != nil {
                textEditBefore = snapshotState()
            } else if oldValue != nil, editingTextID == nil, let before = textEditBefore {
                if before != snapshotState() { pushUndoState(before) }
                textEditBefore = nil
            }
        }
    }

    /// Auto-incrementing value for the next numbered counter badge.
    private(set) var nextCounterNumber = 1

    /// Original geometry of the annotation being moved, captured at drag start.
    private var moveSnapshot: Annotation?

    /// Base-image origin at the start of an image-move drag, plus the editor state
    /// to restore if the move is undone.
    private var imageMoveSnapshot: CGPoint?
    private var imageMoveBefore: EditorState?

    /// Original geometry + grabbed handle of the annotation being resized.
    private var resizeSnapshot: Annotation?
    private var activeHandle: Handle?

    /// Undo / redo history of full editor states (annotations + base image).
    @Published private var undoStack: [EditorState] = []
    @Published private var redoStack: [EditorState] = []
    /// True while applying a history state, so mutations don't re-record.
    private var isApplyingHistory = false
    /// State captured when a text-editing session opened.
    private var textEditBefore: EditorState?

    init(image: CGImage, sourceScale: CGFloat = 2.0, canvasPadding: CGFloat? = nil) {
        self.baseImage = image
        self.baseNSImage = ImageExporter.nsImage(from: image)
        self.sourceScale = sourceScale
        // Seed the editor's style from the configured defaults.
        let settings = CaptureSettings.shared
        self.canvasPadding = canvasPadding ?? CGFloat(settings.canvasPadding)
        let palette = AnnotationStyle.palette
        style.color = palette[safe: settings.defaultColorIndex] ?? .red
        style.textColor = palette[safe: settings.defaultTextColorIndex] ?? .white
        style.fontSize = settings.defaultTextSize
        style.lineWidth = settings.defaultLineWidth
    }

    /// Annotations to render on screen: the committed list (minus the one being
    /// text-edited, which the inline field draws instead) plus the live draft.
    var displayAnnotations: [Annotation] {
        var list = annotations
        if let editingTextID { list.removeAll { $0.id == editingTextID } }
        if let draft { list.append(draft) }
        return list
    }

    /// Image size in pixels.
    var pixelSize: CGSize {
        CGSize(width: baseImage.width, height: baseImage.height)
    }

    /// Image size in logical points (pixels / source scale).
    var logicalSize: CGSize {
        CGSize(width: pixelSize.width / sourceScale, height: pixelSize.height / sourceScale)
    }

    /// Logical-point bounds enclosing the base image (at origin 0,0) plus any
    /// annotations that spill outside it. When something is drawn past an edge,
    /// the origin goes negative and the canvas grows to keep it visible — both
    /// on screen and on export. Equals the image rect when nothing overflows.
    var contentBounds: CGRect { canvasBounds(for: displayAnnotations) }

    /// Like `contentBounds` but excludes the in-progress `draft`, so the editor's
    /// scroll/centering geometry stays put *during* a drag (otherwise starting a
    /// draw outside the image would shift the whole canvas mid-gesture).
    var layoutBounds: CGRect { canvasBounds(for: annotations) }

    /// The base image's rect in canvas (logical) points.
    var imageRect: CGRect { CGRect(origin: imageOrigin, size: logicalSize) }

    func canvasBounds(for annotations: [Annotation]) -> CGRect {
        let image = imageRect
        var raw = image, padded = image
        for a in annotations {
            raw = raw.union(a.boundingBox)
            padded = padded.union(Self.renderBox(a))
        }
        // Grow (with stroke/arrowhead padding) only on edges the geometry actually
        // overflows, so an annotation that exactly fills the image doesn't add a
        // spurious margin.
        let grown = CGRect(corner:
            CGPoint(x: raw.minX < image.minX ? padded.minX : image.minX,
                    y: raw.minY < image.minY ? padded.minY : image.minY),
            CGPoint(x: raw.maxX > image.maxX ? padded.maxX : image.maxX,
                    y: raw.maxY > image.maxY ? padded.maxY : image.maxY))
        // When the canvas extends past the image (an annotation drawn outside),
        // grow it back to the original capture's aspect ratio, centered, so the
        // exported image keeps that ratio.
        return Self.expand(grown, toRatio: image.width / image.height)
    }

    /// Grows `r` (never shrinks) so its width:height equals `ratio`, centered on
    /// `r`. Returns `r` unchanged when it already matches.
    private static func expand(_ r: CGRect, toRatio ratio: CGFloat) -> CGRect {
        guard r.width > 0, r.height > 0, ratio > 0 else { return r }
        let current = r.width / r.height
        if current > ratio {           // too wide → add height
            let h = r.width / ratio
            return CGRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h)
        } else if current < ratio {    // too tall → add width
            let w = r.height * ratio
            return CGRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height)
        }
        return r
    }

    /// Zoom that fits the whole image in `viewport`, never magnifying past 100%.
    /// Reserves `canvasPadding` points of transparent margin on every side so the
    /// capture opens as a small canvas floating in the checkerboard surround.
    func fitZoom(in viewport: CGSize) -> CGFloat {
        guard viewport.width > 0, viewport.height > 0,
              logicalSize.width > 0, logicalSize.height > 0 else { return 1 }
        let padded = CGSize(width: logicalSize.width + canvasPadding * 2,
                            height: logicalSize.height + canvasPadding * 2)
        let fit = min(viewport.width / padded.width, viewport.height / padded.height)
        return min(fit, 1)
    }

    /// Re-fits the capture to the current viewport and resumes auto-fitting on resize.
    func fitAndCenter() {
        hasUserZoomed = false
        zoom = fitZoom(in: viewportSize)
    }

    /// Briefly shows `message` in the editor HUD, then clears it.
    func flash(_ message: String) {
        statusMessage = message
        statusClearTask?.cancel()
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    /// An annotation's drawn extent, padded for stroke width and (for arrows)
    /// the arrowhead, so the grown canvas doesn't clip those overhangs.
    private static func renderBox(_ a: Annotation) -> CGRect {
        var pad = a.style.lineWidth / 2 + 2
        if a.kind == .arrow { pad += max(12, a.style.lineWidth * 4) }
        return a.boundingBox.insetBy(dx: -pad, dy: -pad)
    }

    // MARK: - Drawing gestures (logical-point coordinates)

    /// Called continuously during a drag. `start` is the gesture's origin, `current`
    /// its latest location — both in logical canvas points.
    func dragChanged(start: CGPoint, current: CGPoint) {
        switch activeTool {
        case .select: updateSelectionDrag(start: start, current: current)
        case .crop:   updateCropRect(start: start, current: current)
        default:      updateDraft(start: start, current: current)
        }
    }

    /// Called when a drag (or click) ends.
    func dragEnded(start: CGPoint, current: CGPoint) {
        switch activeTool {
        case .select:
            updateSelectionDrag(start: start, current: current)
            recordInteractionUndo()
            // Record one undo step for an image move that actually shifted it.
            if let before = imageMoveBefore, let snap = imageMoveSnapshot, imageOrigin != snap {
                pushUndoState(before)
            }
            // A click (no real drag) on a text annotation opens it for editing.
            let moved = abs((current - start).width) > 2 || abs((current - start).height) > 2
            if resizeSnapshot == nil, !moved, let id = selectedID,
               annotations.first(where: { $0.id == id })?.kind == .text {
                editingTextID = id
            }
            moveSnapshot = nil
            resizeSnapshot = nil
            activeHandle = nil
            imageMoveSnapshot = nil
            imageMoveBefore = nil
        case .crop:
            updateCropRect(start: start, current: current)
        default:
            updateDraft(start: start, current: current)
            commitDraft()
        }
    }

    /// Points closer together than this along a freehand stroke are dropped. A
    /// drag emits an event per mouse-move regardless of distance, so drawing slowly
    /// piled up near-duplicate points — each one re-stroking the whole path on every
    /// later frame, and re-encoding on export, for no visible fidelity.
    private static let freehandMinSpacing: CGFloat = 1.5

    private func updateDraft(start: CGPoint, current: CGPoint) {
        guard let kind = activeTool.annotationKind else { return }
        editingTextID = nil
        guard draft != nil else {
            draft = makeAnnotation(kind: kind, start: start, current: current)
            return
        }
        // Mutated through the optional rather than copied out into a local and
        // written back — same number of published writes, one less thing to keep
        // in sync. The saving on long strokes comes from `freehandMinSpacing`.
        switch kind {
        case .freehand:
            if let last = draft?.points.last,
               hypot(current.x - last.x, current.y - last.y) < Self.freehandMinSpacing {
                return
            }
            draft?.points.append(current)
        case .line, .arrow:            draft?.points = [start, current]
        case .counter:                 draft?.rect = Self.counterRect(at: current)
        default:                       draft?.rect = CGRect(corner: start, current)
        }
    }

    private func makeAnnotation(kind: AnnotationKind, start: CGPoint, current: CGPoint) -> Annotation {
        var a = Annotation(kind: kind, style: style)
        switch kind {
        case .line, .arrow: a.points = [start, current]
        case .freehand:     a.points = [start]
        case .counter:
            a.rect = Self.counterRect(at: start)
            a.number = nextCounterNumber
        default:            a.rect = CGRect(corner: start, current)
        }
        return a
    }

    /// Commits the in-progress draft, discarding accidental (degenerate) draws.
    func commitDraft() {
        guard var a = draft else { return }
        draft = nil
        guard !a.isDegenerate else { return }
        // Click-to-place text gets a default editable box if it wasn't dragged out.
        if a.kind == .text, a.rect.width < 8 || a.rect.height < 8 {
            a.rect = CGRect(x: a.rect.minX, y: a.rect.minY,
                            width: 160, height: a.style.fontSize * 1.4)
        }
        if a.kind == .counter { nextCounterNumber += 1 }
        recordUndo()
        annotations.append(a)
        selectedID = a.id
        if a.kind == .text { editingTextID = a.id }
    }

    private static func counterRect(at p: CGPoint, diameter: CGFloat = 30) -> CGRect {
        CGRect(x: p.x - diameter / 2, y: p.y - diameter / 2, width: diameter, height: diameter)
    }

    // MARK: - Selection / editing

    /// Topmost annotation whose hit region contains `point`, if any.
    func hitTest(_ point: CGPoint) -> Annotation.ID? {
        for a in annotations.reversed() where a.hitRect().contains(point) {
            return a.id
        }
        return nil
    }

    /// Select-tool drag: grab a resize handle of the current selection if the
    /// gesture started on one, otherwise move (or select) the hit annotation.
    private func updateSelectionDrag(start: CGPoint, current: CGPoint) {
        if moveSnapshot == nil && resizeSnapshot == nil,
           let id = selectedID,
           let a = annotations.first(where: { $0.id == id }),
           let handle = handleHit(at: start, of: a) {
            resizeSnapshot = a
            activeHandle = handle
        }
        if let snap = resizeSnapshot, let handle = activeHandle {
            applyResize(snapshot: snap, handle: handle, to: current)
        } else {
            moveSelection(start: start, current: current)
        }
    }

    private func moveSelection(start: CGPoint, current: CGPoint) {
        if moveSnapshot == nil && imageMoveSnapshot == nil {
            editingTextID = nil
            if let id = hitTest(start) {
                selectedID = id
                moveSnapshot = annotations.first { $0.id == id }
            } else if imageRect.contains(start) {
                // Empty spot over the capture → drag the whole captured image.
                selectedID = nil
                imageMoveSnapshot = imageOrigin
                imageMoveBefore = snapshotState()
            } else {
                selectedID = nil
                return
            }
        }
        if let snap = imageMoveSnapshot {
            imageOrigin = CGPoint(x: snap.x + (current.x - start.x),
                                  y: snap.y + (current.y - start.y))
            return
        }
        guard let snap = moveSnapshot,
              let idx = annotations.firstIndex(where: { $0.id == snap.id }) else { return }
        var moved = snap
        moved.translate(by: current - start)
        annotations[idx] = moved
    }

    func deleteSelected() {
        guard let id = selectedID,
              let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        recordUndo()
        annotations.remove(at: idx)
        selectedID = nil
        editingTextID = nil
    }

    func deselect() {
        selectedID = nil
        editingTextID = nil
    }

    /// What the Esc key should do, given current editor state and the
    /// `escCopiesAndCloses` setting. Cancelling a pending crop and deselecting take
    /// priority; only when there's nothing to undo does Esc act as "copy and close".
    enum EscapeAction: Equatable { case cancelCrop, deselect, copyAndClose }

    func escapeAction(escCopiesAndCloses: Bool) -> EscapeAction {
        if cropRect != nil { return .cancelCrop }
        if selectedID != nil { return .deselect }
        return escCopiesAndCloses ? .copyAndClose : .deselect
    }

    // MARK: - Resize handles

    /// A grabbable point on a selected annotation. `start`/`end` are the two
    /// ends of a line/arrow; the rest are the corners and edge midpoints of a
    /// box (freehand uses only the four corners).
    enum Handle: Hashable {
        case start, end
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    /// Handle positions for `a` in logical points, keyed by handle. Empty when
    /// the annotation has no meaningful handles.
    func handlePositions(of a: Annotation) -> [Handle: CGPoint] {
        switch a.kind {
        case .line, .arrow:
            guard a.points.count >= 2 else { return [:] }
            return [.start: a.points[0], .end: a.points[1]]
        case .freehand:
            let r = a.boundingBox
            guard r.width > 0 || r.height > 0 else { return [:] }
            return [.topLeft: CGPoint(x: r.minX, y: r.minY),
                    .topRight: CGPoint(x: r.maxX, y: r.minY),
                    .bottomLeft: CGPoint(x: r.minX, y: r.maxY),
                    .bottomRight: CGPoint(x: r.maxX, y: r.maxY)]
        default:
            let r = a.rect
            return [.topLeft: CGPoint(x: r.minX, y: r.minY),
                    .top: CGPoint(x: r.midX, y: r.minY),
                    .topRight: CGPoint(x: r.maxX, y: r.minY),
                    .right: CGPoint(x: r.maxX, y: r.midY),
                    .bottomRight: CGPoint(x: r.maxX, y: r.maxY),
                    .bottom: CGPoint(x: r.midX, y: r.maxY),
                    .bottomLeft: CGPoint(x: r.minX, y: r.maxY),
                    .left: CGPoint(x: r.minX, y: r.midY)]
        }
    }

    /// The handle of `a` whose position is within `tolerance` of `p`, if any.
    private func handleHit(at p: CGPoint, of a: Annotation, tolerance: CGFloat = 9) -> Handle? {
        let t = tolerance / max(zoom, 0.0001)
        return handlePositions(of: a).first {
            abs(p.x - $0.value.x) <= t && abs(p.y - $0.value.y) <= t
        }?.key
    }

    private func applyResize(snapshot: Annotation, handle: Handle, to p: CGPoint) {
        guard let idx = annotations.firstIndex(where: { $0.id == snapshot.id }) else { return }
        var a = snapshot
        switch a.kind {
        case .line, .arrow:
            if handle == .start { a.points[0] = p } else if handle == .end { a.points[1] = p }
        case .freehand:
            scaleFreehand(&a, from: snapshot, handle: handle, to: p)
        case .counter:
            a.rect = squared(resizedRect(snapshot.rect, handle: handle, to: p))
        default:
            a.rect = resizedRect(snapshot.rect, handle: handle, to: p)
        }
        annotations[idx] = a
    }

    /// `rect` with the edge(s) named by `handle` moved so the grabbed corner/edge
    /// follows `p`; the opposite side stays put. Normalized so it can't invert.
    private func resizedRect(_ rect: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch handle {
        case .topLeft:     minX = p.x; minY = p.y
        case .top:         minY = p.y
        case .topRight:    maxX = p.x; minY = p.y
        case .right:       maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom:      maxY = p.y
        case .bottomLeft:  minX = p.x; maxY = p.y
        case .left:        minX = p.x
        case .start, .end: break
        }
        return CGRect(corner: CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
    }

    /// A square version of `rect` (largest side), centered on `rect` — keeps the
    /// counter badge circular as it's resized.
    private func squared(_ rect: CGRect) -> CGRect {
        let side = max(rect.width, rect.height)
        return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    /// Scales every freehand point so the dragged bounding-box corner follows `p`
    /// while the opposite corner stays anchored.
    private func scaleFreehand(_ a: inout Annotation, from snap: Annotation, handle: Handle, to p: CGPoint) {
        let r = snap.boundingBox
        let anchor: CGPoint
        let corner: CGPoint
        switch handle {
        case .topLeft:     anchor = CGPoint(x: r.maxX, y: r.maxY); corner = CGPoint(x: r.minX, y: r.minY)
        case .topRight:    anchor = CGPoint(x: r.minX, y: r.maxY); corner = CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft:  anchor = CGPoint(x: r.maxX, y: r.minY); corner = CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: anchor = CGPoint(x: r.minX, y: r.minY); corner = CGPoint(x: r.maxX, y: r.maxY)
        default:           return
        }
        let dx = corner.x - anchor.x, dy = corner.y - anchor.y
        let sx = abs(dx) > 0.5 ? (p.x - anchor.x) / dx : 1
        let sy = abs(dy) > 0.5 ? (p.y - anchor.y) / dy : 1
        a.points = snap.points.map {
            CGPoint(x: anchor.x + ($0.x - anchor.x) * sx,
                    y: anchor.y + ($0.y - anchor.y) * sy)
        }
    }

    // MARK: - Crop

    private func updateCropRect(start: CGPoint, current: CGPoint) {
        cropRect = CGRect(corner: start, current).intersection(imageRect)
    }

    /// Crops the base image to the pending `cropRect` (converted to pixels) and
    /// re-anchors annotations to the new top-left origin. No-op for a trivial rect.
    func applyCrop() {
        defer { cropRect = nil }
        guard let rect = cropRect, rect.width > 4, rect.height > 4 else { return }

        let pixelBounds = CGRect(x: 0, y: 0, width: CGFloat(baseImage.width), height: CGFloat(baseImage.height))
        // Crop rect is in canvas coords; convert to image-local pixels.
        let local = rect.offsetBy(dx: -imageOrigin.x, dy: -imageOrigin.y)
        let pixelRect = CGRect(x: local.minX * sourceScale, y: local.minY * sourceScale,
                               width: local.width * sourceScale, height: local.height * sourceScale)
            .intersection(pixelBounds)
            .integral
        guard let cropped = baseImage.cropping(to: pixelRect) else { return }

        recordUndo()
        baseImage = cropped
        // Re-anchor everything so the crop's top-left becomes the new origin.
        let delta = CGSize(width: -rect.minX, height: -rect.minY)
        for i in annotations.indices { annotations[i].translate(by: delta) }
        imageOrigin = .zero
        activeTool = .select
        selectedID = nil
        Log.editor.info("cropped to \(cropped.width)×\(cropped.height)px")
    }

    func cancelCrop() {
        cropRect = nil
    }

    // MARK: - Undo / redo

    /// A restorable editor snapshot. `baseImage` is compared by identity (crop
    /// swaps in a new instance), the rest by value.
    private struct EditorState: Equatable {
        var annotations: [Annotation]
        var baseImage: CGImage
        var nextCounterNumber: Int
        var imageOrigin: CGPoint

        static func == (l: EditorState, r: EditorState) -> Bool {
            l.nextCounterNumber == r.nextCounterNumber
                && l.baseImage === r.baseImage
                && l.imageOrigin == r.imageOrigin
                && l.annotations == r.annotations
        }
    }

    private static let maxHistory = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func snapshotState() -> EditorState {
        EditorState(annotations: annotations, baseImage: baseImage,
                    nextCounterNumber: nextCounterNumber, imageOrigin: imageOrigin)
    }

    /// Pushes the current state so the next mutation can be undone. Call *before*
    /// mutating. No-op while applying history.
    private func recordUndo() { pushUndoState(snapshotState()) }

    private func pushUndoState(_ state: EditorState) {
        guard !isApplyingHistory else { return }
        undoStack.append(state)
        if undoStack.count > Self.maxHistory { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Records one undo step for a just-finished move/resize, if it changed the
    /// annotation. Uses the pre-drag snapshot, so a plain click doesn't pollute
    /// the history.
    private func recordInteractionUndo() {
        guard let snap = resizeSnapshot ?? moveSnapshot,
              let idx = annotations.firstIndex(where: { $0.id == snap.id }),
              annotations[idx] != snap else { return }
        var before = snapshotState()
        before.annotations[idx] = snap
        pushUndoState(before)
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(snapshotState())
        apply(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshotState())
        apply(next)
    }

    private func apply(_ state: EditorState) {
        isApplyingHistory = true
        defer { isApplyingHistory = false }
        annotations = state.annotations
        nextCounterNumber = state.nextCounterNumber
        baseImage = state.baseImage
        imageOrigin = state.imageOrigin
        draft = nil
        editingTextID = nil
        selectedID = nil
        cropRect = nil
        textEditBefore = nil
        imageMoveSnapshot = nil
        imageMoveBefore = nil
    }

    // MARK: - Style

    /// Updates the active style and applies it to the current selection, so the
    /// toolbar drives both new annotations and the selected one. Each setter
    /// touches only its own field — assigning the whole style would stomp the
    /// selection's other properties with stale toolbar values.
    func setColor(_ color: Color) {
        if selectedID != nil { recordUndo() }
        style.color = color
        applyToSelection { $0.color = color }
    }

    func setLineWidth(_ width: CGFloat) {
        style.lineWidth = width
        applyToSelection { $0.lineWidth = width }
    }

    func setFontSize(_ size: CGFloat) {
        style.fontSize = size
        applyToSelection { $0.fontSize = size }
        if let id = selectedID { syncTextRect(id) }
    }

    /// Records one undo step when a style-slider drag starts on a selection —
    /// the continuous `setLineWidth`/`setFontSize` calls don't record, so a
    /// whole drag undoes in a single step instead of dozens (or none).
    func styleSliderEditingChanged(_ began: Bool) {
        if began, selectedID != nil { recordUndo() }
    }

    /// Flips the text-background pill on/off for new text and the current selection.
    func toggleTextBackground() {
        if selectedID != nil { recordUndo() }
        style.textBackground.toggle()
        let value = style.textBackground
        applyToSelection { $0.textBackground = value }
        if let id = selectedID { syncTextRect(id) }
    }

    private func applyToSelection(_ mutate: (inout AnnotationStyle) -> Void) {
        guard let id = selectedID,
              let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&annotations[idx].style)
    }

    /// Two-way binding to a text annotation's string, for the inline editor.
    func textBinding(for id: Annotation.ID) -> Binding<String> {
        Binding(
            get: { self.annotations.first(where: { $0.id == id })?.text ?? "" },
            set: { newValue in
                if let idx = self.annotations.firstIndex(where: { $0.id == id }) {
                    self.annotations[idx].text = newValue
                    self.syncTextRect(id)
                }
            }
        )
    }

    /// Resizes a text annotation's `rect` to its rendered extent (pill padding
    /// included). The stored rect drives hit-testing, the selection box, and
    /// canvas growth/export bounds — without this, long text overflows its
    /// creation-time box and can be clipped on export.
    private func syncTextRect(_ id: Annotation.ID) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }),
              annotations[idx].kind == .text else { return }
        annotations[idx].rect.size = Self.renderedTextSize(annotations[idx])
    }

    /// Measured drawn size of a text annotation, matching `AnnotationLayer.drawText`
    /// (system semibold font; +8/+4 pill padding per side when backgrounded).
    static func renderedTextSize(_ a: Annotation) -> CGSize {
        let string = a.text.isEmpty ? " " : a.text
        let font = NSFont.systemFont(ofSize: a.style.fontSize, weight: .semibold)
        var size = (string as NSString).size(withAttributes: [.font: font])
        if a.style.textBackground {
            size.width += 16
            size.height += 8
        }
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    // MARK: - Export

    /// Flattens the base image + annotations to a full-resolution `CGImage` by
    /// rendering the same `FlatCanvas` shown on screen at the source scale.
    func flatten() -> CGImage {
        guard !annotations.isEmpty else { return baseImage }
        let bounds = canvasBounds(for: annotations)
        let renderer = ImageRenderer(content:
            FlatCanvas(baseImage: baseImage, baseNSImage: baseNSImage,
                       imageSize: logicalSize, contentBounds: bounds,
                       imageOrigin: imageOrigin,
                       annotations: annotations))
        renderer.proposedSize = ProposedViewSize(bounds.size)
        renderer.scale = sourceScale
        return renderer.cgImage ?? baseImage
    }

    func copyToClipboard() {
        ImageExporter.copyToPasteboard(flatten())
        flash("Copied to clipboard")
        if CaptureSettings.shared.closeAfterCopy { requestClose?() }
    }

    /// Saves straight to the directory configured in Settings, no prompt.
    func save() {
        let settings = CaptureSettings.shared
        var image = flatten()
        if settings.downscaleRetina {
            image = ImageExporter.downscaled(image, by: sourceScale)
        }
        let url = ImageExporter.saveSilently(image, to: settings.saveDirectory, format: settings.saveFormat)
        flash(url.map { "Saved \($0.lastPathComponent)" } ?? "Save failed")
        if url != nil, settings.closeAfterSave { requestClose?() }
    }
}
