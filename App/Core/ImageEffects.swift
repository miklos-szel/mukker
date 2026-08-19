import CoreImage
import CoreGraphics

/// Pixel-level image effects used by annotations that transform the underlying
/// capture (e.g. the blur/pixelate redaction tool) rather than draw over it.
enum ImageEffects {
    private static let context = CIContext(options: nil)

    /// A pixelated ("mosaic") copy of `cg`, sized identically. The block size
    /// scales with resolution so retina captures get visibly chunky blocks.
    static func pixellate(_ cg: CGImage) -> CGImage? {
        let input = CIImage(cgImage: cg)
        let scale = max(6, CGFloat(cg.width) / 128)
        guard let filter = CIFilter(name: "CIPixellate", parameters: [
            kCIInputImageKey: input,
            kCIInputScaleKey: scale,
            kCIInputCenterKey: CIVector(x: 0, y: 0)
        ]), let output = filter.outputImage else { return nil }
        // CIPixellate dilates the extent; crop back to the original bounds.
        return context.createCGImage(output, from: input.extent)
    }
}
