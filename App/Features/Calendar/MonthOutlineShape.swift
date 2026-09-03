import SwiftUI

/// The rounded, stepped outline around exactly the cells belonging to the grid's
/// anchor month — what separates the month from the leading/trailing days it
/// borrows from its neighbours.
///
/// The shape is a staircase of at most three runs (a partial first row, a full
/// block, a partial last row), so its corners are enumerable rather than traced:
/// `corners` returns them clockwise and `path(in:)` walks them with
/// `addArc(tangent1End:tangent2End:radius:)`, which rounds the two *concave*
/// steps exactly like the convex corners.
///
/// Geometry comes from `cell`, not from the rect it is asked to draw into — the
/// view hands it a frame the size of the six week rows, and the grid has no
/// spacing between rows for precisely this reason.
struct MonthOutlineShape: Shape {
    /// First and last grid index of the month, from `CalendarGrid.monthSpan`.
    let span: ClosedRange<Int>
    let cell: CGSize
    var cornerRadius: CGFloat = 7

    /// Clockwise corners of the staircase, in the grid's own coordinates (y grows
    /// down). Four points when the month fills both its first and last row, six
    /// when one of them is partial, eight when both are.
    nonisolated static func corners(span: ClosedRange<Int>,
                                    cell: CGSize,
                                    columns: Int = CalendarGrid.columns) -> [CGPoint] {
        let firstRow = span.lowerBound / columns
        let firstColumn = span.lowerBound % columns
        let lastRow = span.upperBound / columns
        // Exclusive, so it can equal `columns` when the last row is full.
        let lastColumn = span.upperBound % columns + 1

        func x(_ column: Int) -> CGFloat { CGFloat(column) * cell.width }
        func y(_ row: Int) -> CGFloat { CGFloat(row) * cell.height }

        // A real month spans at least four rows; a single-row span would make the
        // polygon below fold over itself, so it degenerates to a plain rectangle.
        guard lastRow > firstRow else {
            return [CGPoint(x: x(firstColumn), y: y(firstRow)),
                    CGPoint(x: x(lastColumn), y: y(firstRow)),
                    CGPoint(x: x(lastColumn), y: y(firstRow + 1)),
                    CGPoint(x: x(firstColumn), y: y(firstRow + 1))]
        }

        var points = [CGPoint(x: x(firstColumn), y: y(firstRow)),
                      CGPoint(x: x(columns), y: y(firstRow))]
        if lastColumn < columns {
            points.append(CGPoint(x: x(columns), y: y(lastRow)))
            points.append(CGPoint(x: x(lastColumn), y: y(lastRow)))
        }
        points.append(CGPoint(x: x(lastColumn), y: y(lastRow + 1)))
        points.append(CGPoint(x: x(0), y: y(lastRow + 1)))
        if firstColumn > 0 {
            points.append(CGPoint(x: x(0), y: y(firstRow + 1)))
            points.append(CGPoint(x: x(firstColumn), y: y(firstRow + 1)))
        }
        return points
    }

    func path(in rect: CGRect) -> Path {
        let points = Self.corners(span: span, cell: cell)
        guard points.count >= 4 else { return Path() }
        let radius = min(cornerRadius, Self.shortestEdge(points) / 2)

        var path = Path()
        // Starting mid-edge keeps every corner's arc in one piece — beginning on a
        // corner would split its arc across `closeSubpath`.
        path.move(to: CGPoint(x: (points[0].x + points[1].x) / 2,
                              y: (points[0].y + points[1].y) / 2))
        for offset in 1...points.count {
            path.addArc(tangent1End: points[offset % points.count],
                        tangent2End: points[(offset + 1) % points.count],
                        radius: radius)
        }
        path.closeSubpath()
        return path
    }

    private nonisolated static func shortestEdge(_ points: [CGPoint]) -> CGFloat {
        (0..<points.count).map { index -> CGFloat in
            let a = points[index], b = points[(index + 1) % points.count]
            return abs(a.x - b.x) + abs(a.y - b.y)   // every edge is axis-aligned
        }.min() ?? 0
    }
}
