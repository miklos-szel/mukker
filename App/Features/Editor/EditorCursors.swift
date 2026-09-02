import AppKit
import SwiftUI

/// Maps the active tool to the pointer shown over the canvas. Until this existed
/// every tool showed the plain arrow, so nothing told you whether the next drag
/// would draw, pan, or crop.
///
/// The mapping is `nonisolated static` and free of AppKit state so it can be
/// covered by `AppTests` without a window or a permission grant — the same split
/// used by `CalendarGrid` and `WindowTiler`.
enum EditorCursors {
    /// The cursor for `tool`. `panning` is true while a hand-tool drag is in
    /// flight, which is the only state that changes a tool's cursor mid-gesture.
    nonisolated static func cursor(for tool: Tool, panning: Bool = false) -> NSCursor {
        switch tool {
        case .select:
            return .arrow
        case .hand:
            return panning ? .closedHand : .openHand
        case .text:
            return .iBeam
        case .crop, .arrow, .line, .rectangle, .roundedRectangle,
             .ellipse, .highlight, .blur, .freehand, .counter:
            return .crosshair
        }
    }

    /// The cursor for a selection resize handle. Corner handles keep the
    /// crosshair — AppKit ships no public diagonal resize cursor, and the
    /// straight two-way arrows would point the wrong way.
    nonisolated static func cursor(for handle: EditorViewModel.Handle) -> NSCursor {
        switch handle {
        case .start, .end, .topLeft, .topRight, .bottomLeft, .bottomRight:
            return .crosshair
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        }
    }
}

extension View {
    /// Shows `tool`'s cursor while the pointer is over this view.
    ///
    /// Built on `onContinuousHover` + `NSCursor.set()` rather than cursor rects or
    /// a `push`/`pop` pair: an `NSTrackingArea` competes with the SwiftUI hosting
    /// view's own hit testing (and with the enclosing `ScrollView`), and a
    /// push/pop stack goes out of balance whenever a gesture ends outside the view.
    /// Re-asserting `set()` on each move is cheap and self-correcting.
    func editorCursor(tool: Tool, panning: Bool) -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active:
                EditorCursors.cursor(for: tool, panning: panning).set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
    }
}
