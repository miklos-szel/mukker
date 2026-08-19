import CoreGraphics
import Foundation

enum AnnotationKind: Equatable {
    case arrow
    case line
    case rectangle
    case roundedRectangle
    case ellipse
    case highlight
    case blur
    case text
    case freehand
    case counter
}

/// One annotation in **image logical-point** coordinates (zoom-independent).
///
/// Geometry is stored per family:
/// - box kinds (rect, roundedRect, ellipse, highlight, text): `rect` is the bounds.
/// - `line` / `arrow`: `points[0]` = start, `points[1]` = end.
/// - `freehand`: `points` is the stroke path.
/// - `counter`: `rect` is the badge bounds; `number` is the displayed value.
struct Annotation: Identifiable, Equatable {
    let id = UUID()
    var kind: AnnotationKind
    var rect: CGRect = .zero
    var points: [CGPoint] = []
    var text: String = ""
    var number: Int = 1
    var style: AnnotationStyle

    /// Axis-aligned bounds used for hit-testing and selection handles.
    var boundingBox: CGRect {
        switch kind {
        case .line, .arrow, .freehand:
            guard let first = points.first else { return rect }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for p in points {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        default:
            return rect
        }
    }

    mutating func translate(by delta: CGSize) {
        rect = rect.offsetBy(dx: delta.width, dy: delta.height)
        points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
    }

    /// Selection hit region, padded so thin shapes (lines, strokes) stay grabbable.
    func hitRect(tolerance: CGFloat = 6) -> CGRect {
        boundingBox.insetBy(dx: -tolerance, dy: -tolerance)
    }

    /// True when a freshly drawn shape is too small to keep — e.g. an accidental
    /// click rather than a deliberate drag. Click-to-place kinds are never degenerate.
    var isDegenerate: Bool {
        switch kind {
        case .freehand:
            return points.count < 2
        case .line, .arrow:
            guard points.count >= 2 else { return true }
            let d = points[0] - points[1]
            return abs(d.width) < 3 && abs(d.height) < 3
        case .counter, .text:
            return false
        default:
            return rect.width < 3 && rect.height < 3
        }
    }
}
