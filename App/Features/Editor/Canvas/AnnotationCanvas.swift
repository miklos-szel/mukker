import AppKit
import SwiftUI

/// The base image with all annotations composited on top, sized in logical
/// points. This exact view is what `ImageRenderer` flattens on export, so the
/// editor preview and the saved/copied result stay identical.
///
/// `contentBounds` is the canvas extent in image coordinates: it equals the
/// image rect (origin 0,0) until an annotation spills past an edge, at which
/// point the origin goes negative and the canvas grows. Everything is shifted
/// by `-contentBounds.origin` so the grown region lands in positive space.
struct FlatCanvas: View {
    let baseImage: CGImage
    /// `baseImage` wrapped for SwiftUI, cached by the view model. Built here it
    /// would be a fresh `NSImage` on every body pass — i.e. every frame of a drag,
    /// each one re-running the high-quality resample of a full retina screenshot.
    let baseNSImage: NSImage
    /// Logical size of the base image.
    let imageSize: CGSize
    /// Union of the image rect and any overflowing annotations, in image coords.
    let contentBounds: CGRect
    /// Top-left of the base image in canvas coords (the image can be moved around).
    var imageOrigin: CGPoint = .zero
    let annotations: [Annotation]

    var body: some View {
        let offset = CGSize(width: imageOrigin.x - contentBounds.minX,
                            height: imageOrigin.y - contentBounds.minY)
        ZStack(alignment: .topLeading) {
            // White matte over the whole content/export region, so draw-outside
            // overflow is white both on screen and in the exported image (the base
            // image covers its own area when nothing spills over).
            Color.white
                .frame(width: contentBounds.width, height: contentBounds.height)
            Image(nsImage: baseNSImage)
                .resizable()
                .interpolation(.high)
                .frame(width: imageSize.width, height: imageSize.height)
                .offset(offset)
            AnnotationLayer(annotations: annotations,
                            imageSize: imageSize,
                            contentOrigin: contentBounds.origin,
                            imageOrigin: imageOrigin,
                            baseImage: baseImage)
                .frame(width: contentBounds.width, height: contentBounds.height)
        }
        .frame(width: contentBounds.width, height: contentBounds.height, alignment: .topLeading)
    }
}
