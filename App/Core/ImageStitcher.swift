import CoreGraphics

/// Stitches the frames of a scrolling capture into one tall image by matching
/// the overlap between consecutive (same-size) viewport frames.
///
/// All functions are pure so the matching can be unit-tested without any real
/// capture. **Known limitation:** sticky headers/footers that don't scroll with
/// the content degrade the row matching and can produce duplicated bands.
enum ImageStitcher {

    /// Per-row luminance signatures, indexed **top → bottom** (index 0 is the top
    /// image row). Columns are sampled for speed.
    static func rowSignatures(_ cg: CGImage) -> [Double] {
        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return [] }
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let success = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { return [] }

        let step = max(1, width / 64)
        var signatures = [Double](repeating: 0, count: height)
        for row in 0..<height {
            var sum = 0.0
            var samples = 0
            var x = 0
            while x < width {
                let i = row * bytesPerRow + x * 4
                sum += 0.299 * Double(buffer[i]) + 0.587 * Double(buffer[i + 1]) + 0.114 * Double(buffer[i + 2])
                samples += 1
                x += step
            }
            // The drawn buffer is top-row-first, so index 0 is already the top row.
            signatures[row] = sum / Double(samples)
        }
        return signatures
    }

    /// How far (in pixels) `next` advanced past `base` — i.e. how many new rows
    /// appeared at the bottom. 0 means no new content (bottom reached / identical
    /// frames). Found by matching `next`'s top against `base`'s bottom.
    static func scrollDistance(base: [Double], next: [Double], maxStep: Int) -> Int {
        let height = min(base.count, next.count)
        guard height > 1 else { return 0 }
        let upper = min(maxStep, height - 1)

        var bestOffset = 0
        var bestScore = Double.greatestFiniteMagnitude
        for d in 0...upper {
            let overlap = height - d
            var score = 0.0
            for i in 0..<overlap {
                let diff = base[d + i] - next[i]
                score += diff * diff
            }
            score /= Double(overlap)
            if score < bestScore {
                bestScore = score
                bestOffset = d
            }
        }
        return bestOffset
    }

    /// Composites `strips` top → bottom into a single image of the given width.
    static func verticalStack(_ strips: [CGImage], width: Int) -> CGImage? {
        let totalHeight = strips.reduce(0) { $0 + $1.height }
        guard width > 0, totalHeight > 0,
              let ctx = CGContext(
                data: nil, width: width, height: totalHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        var topOffset = 0
        for strip in strips {
            let h = strip.height
            // bottom-left origin: a strip at top-offset `topOffset` sits at this y.
            let y = totalHeight - (topOffset + h)
            ctx.draw(strip, in: CGRect(x: 0, y: y, width: width, height: h))
            topOffset += h
        }
        return ctx.makeImage()
    }
}
