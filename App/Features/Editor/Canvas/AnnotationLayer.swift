import SwiftUI

/// Draws every annotation with a single SwiftUI `Canvas`, in logical-point
/// coordinates. Used by both the on-screen canvas and the export renderer, so
/// what you see is what gets flattened.
struct AnnotationLayer: View {
    let annotations: [Annotation]
    /// Logical size of the base image (used to place the blur reveal layer).
    let imageSize: CGSize
    /// Top-left of the (possibly grown) canvas in image coordinates. Drawing is
    /// translated by `-contentOrigin` so annotations in negative space land on
    /// the canvas. Defaults to zero (canvas == image).
    var contentOrigin: CGPoint = .zero
    /// Top-left of the base image in canvas coords (for placing the blur reveal).
    var imageOrigin: CGPoint = .zero
    /// The base image, so a blur can obscure it (and the annotations beneath it).
    var baseImage: CGImage?

    var body: some View {
        Canvas { context, _ in
            context.translateBy(x: -contentOrigin.x, y: -contentOrigin.y)
            for index in annotations.indices {
                let annotation = annotations[index]
                if annotation.kind == .blur {
                    // Blur obscures everything underneath: the base image plus all
                    // annotations drawn before it.
                    drawBlur(annotation, below: Array(annotations[..<index]), in: &context)
                } else {
                    draw(annotation, in: &context)
                }
            }
        }
    }

    private func draw(_ a: Annotation, in ctx: inout GraphicsContext) {
        let stroke = StrokeStyle(lineWidth: a.style.lineWidth, lineCap: .round, lineJoin: .round)
        switch a.kind {
        case .rectangle:
            sketchStroke(Path(a.rect), a, in: &ctx)
        case .roundedRectangle:
            sketchStroke(Path(roundedRect: a.rect,
                              cornerSize: CGSize(width: a.style.cornerRadius, height: a.style.cornerRadius)),
                         a, in: &ctx)
        case .ellipse:
            ctx.stroke(Path(ellipseIn: a.rect), with: .color(a.style.color), style: stroke)
        case .highlight:
            let radius = min(6, min(a.rect.width, a.rect.height) / 2)
            ctx.fill(Path(roundedRect: a.rect, cornerRadius: radius),
                     with: .color(a.style.color.opacity(a.style.fillOpacity)))
        case .blur:
            break   // handled in the body loop (needs the annotations beneath it)
        case .line:
            ctx.stroke(linePath(a), with: .color(a.style.color), style: stroke)
        case .arrow:
            drawArrow(a, in: &ctx)
        case .freehand:
            ctx.stroke(freehandPath(a), with: .color(a.style.color), style: stroke)
        case .text:
            drawText(a, in: &ctx)
        case .counter:
            drawCounter(a, in: &ctx)
        }
    }

    private func linePath(_ a: Annotation) -> Path {
        var path = Path()
        guard a.points.count >= 2 else { return path }
        path.move(to: a.points[0]); path.addLine(to: a.points[1])
        return path
    }

    /// A tapered shaft (thin at the tail, thicker toward the head) plus a solid
    /// triangular head. The shaft stops at the head's base so it never pokes
    /// through the tip.
    private func drawArrow(_ a: Annotation, in ctx: inout GraphicsContext) {
        guard a.points.count >= 2 else { return }
        let start = a.points[0], end = a.points[1]
        let lw = a.style.lineWidth
        let dist = max(hypot(end.x - start.x, end.y - start.y), 0.001)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = min(max(14, lw * 3.2), dist * 0.95)
        let headWidth = max(10, lw * 3.0)

        let base = CGPoint(x: end.x - cos(angle) * headLength,
                           y: end.y - sin(angle) * headLength)
        let perp = angle + .pi / 2
        let cosP = cos(perp), sinP = sin(perp)

        // Shaft as a filled quadrilateral tapering from a thin tail to a wider
        // base where it meets the arrowhead.
        let tailHalf = max(lw * 0.35, 0.75)
        let baseHalf = max(lw * 0.6, 1.0)
        var shaft = Path()
        shaft.move(to: CGPoint(x: start.x + cosP * tailHalf, y: start.y + sinP * tailHalf))
        shaft.addLine(to: CGPoint(x: base.x + cosP * baseHalf, y: base.y + sinP * baseHalf))
        shaft.addLine(to: CGPoint(x: base.x - cosP * baseHalf, y: base.y - sinP * baseHalf))
        shaft.addLine(to: CGPoint(x: start.x - cosP * tailHalf, y: start.y - sinP * tailHalf))
        shaft.closeSubpath()
        ctx.fill(shaft, with: .color(a.style.color))
        // Round off the tail so it doesn't look chopped.
        ctx.fill(Path(ellipseIn: CGRect(x: start.x - tailHalf, y: start.y - tailHalf,
                                        width: tailHalf * 2, height: tailHalf * 2)),
                 with: .color(a.style.color))

        let half = headWidth / 2
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: base.x + cosP * half, y: base.y + sinP * half))
        head.addLine(to: CGPoint(x: base.x - cosP * half, y: base.y - sinP * half))
        head.closeSubpath()
        ctx.fill(head, with: .color(a.style.color))
    }

    /// Strokes `path` with a lively, hand-drawn marker feel: two overlaid passes
    /// with a slight, *deterministic* offset and width variation (seeded from the
    /// rect so it doesn't shimmer between frames). Used for rectangles.
    private func sketchStroke(_ path: Path, _ a: Annotation, in ctx: inout GraphicsContext) {
        let lw = a.style.lineWidth
        let color = a.style.color
        // Seed a tiny, stable jitter from the annotation's geometry.
        let r = a.rect
        let seed = (r.minX * 0.13 + r.minY * 0.07 + r.width * 0.03).truncatingRemainder(dividingBy: 1)
        let jitter = (seed - 0.5) * min(lw * 0.5, 2.0)
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        let ghost = path.offsetBy(dx: jitter, dy: -jitter)
        ctx.stroke(ghost, with: .color(color.opacity(0.85)),
                   style: StrokeStyle(lineWidth: max(lw * 0.85, 1), lineCap: .round, lineJoin: .round))
    }

    private func freehandPath(_ a: Annotation) -> Path {
        var path = Path()
        guard let first = a.points.first else { return path }
        path.move(to: first)
        for p in a.points.dropFirst() { path.addLine(to: p) }
        return path
    }

    /// Blurs everything beneath the annotation's rect — the base image and any
    /// annotations drawn before it — by redrawing them through a blur filter,
    /// clipped to the rect. So objects under a blur are scrambled, not erased.
    private func drawBlur(_ a: Annotation, below: [Annotation], in ctx: inout GraphicsContext) {
        let radius = min(max(min(a.rect.width, a.rect.height) * 0.08, 6), 25)
        ctx.drawLayer { layer in
            layer.clip(to: Path(a.rect))
            layer.addFilter(.blur(radius: radius))
            if let baseImage {
                layer.draw(Image(decorative: baseImage, scale: 1),
                           in: CGRect(origin: imageOrigin, size: imageSize))
            } else {
                layer.fill(Path(a.rect), with: .color(.gray))
            }
            for b in below where b.kind != .blur {
                draw(b, in: &layer)
            }
        }
    }

    private func drawText(_ a: Annotation, in ctx: inout GraphicsContext) {
        let string = a.text.isEmpty ? " " : a.text
        if a.style.textBackground {
            // Text (in textColor) on a filled rounded pill in the style color.
            let text = Text(string)
                .font(.system(size: a.style.fontSize, weight: .semibold))
                .foregroundStyle(a.style.textColor)
            let padX: CGFloat = 8, padY: CGFloat = 4
            let size = ctx.resolve(text).measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
            let pill = CGRect(x: a.rect.minX, y: a.rect.minY,
                              width: size.width + padX * 2, height: size.height + padY * 2)
            ctx.fill(Path(roundedRect: pill, cornerRadius: 6), with: .color(a.style.color))
            ctx.draw(text, at: CGPoint(x: pill.minX + padX, y: pill.minY + padY), anchor: .topLeading)
        } else {
            let text = Text(string)
                .font(.system(size: a.style.fontSize, weight: .semibold))
                .foregroundStyle(a.style.color)
            ctx.draw(text, at: CGPoint(x: a.rect.minX, y: a.rect.minY), anchor: .topLeading)
        }
    }

    private func drawCounter(_ a: Annotation, in ctx: inout GraphicsContext) {
        ctx.fill(Path(ellipseIn: a.rect), with: .color(a.style.color))
        let label = Text("\(a.number)")
            .font(.system(size: a.rect.height * 0.55, weight: .bold))
            .foregroundStyle(.white)
        ctx.draw(label, at: CGPoint(x: a.rect.midX, y: a.rect.midY), anchor: .center)
    }
}
