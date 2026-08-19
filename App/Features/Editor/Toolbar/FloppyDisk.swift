import SwiftUI

/// A classic floppy-disk "save" glyph. SF Symbols has no floppy, so we draw one.
/// Fill it with `FillStyle(eoFill: true)` so the label and shutter read as
/// cut-outs:
///
///     FloppyDisk().fill(Color.primary, style: FillStyle(eoFill: true))
struct FloppyDisk: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + fx * rect.width, y: rect.minY + fy * rect.height)
        }
        var path = Path()
        // Body, with the trademark clipped top-right corner and softened corners.
        path.move(to: p(0.05, 0))
        path.addLine(to: p(0.72, 0))
        path.addLine(to: p(1.0, 0.28))
        path.addLine(to: p(1.0, 0.95))
        path.addLine(to: p(0.95, 1.0))
        path.addLine(to: p(0.05, 1.0))
        path.addLine(to: p(0, 0.95))
        path.addLine(to: p(0, 0.05))
        path.closeSubpath()
        // Bottom label cut-out.
        path.addRect(CGRect(corner: p(0.24, 0.55), p(0.76, 0.86)))
        // Shutter window cut-out near the top.
        path.addRect(CGRect(corner: p(0.58, 0.12), p(0.74, 0.40)))
        return path
    }
}
