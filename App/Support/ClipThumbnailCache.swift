import AppKit
import ImageIO

/// Caches decoded images for image clip items so the popup never decodes a
/// full-size PNG during list rendering (rows previously re-read the file on
/// every render, i.e. on every arrow-key press).
///
/// Images are decoded with ImageIO's thumbnail API, which downsamples while
/// decoding — a 5K screenshot never gets inflated to full size just to draw a
/// 20 pt row icon or a preview a few hundred points wide.
///
/// Keys are file paths; image files are content-addressed (named by their
/// SHA-256), so a cached entry can never go stale — the same path always
/// holds the same bytes.
@MainActor
final class ClipThumbnailCache {
    static let shared = ClipThumbnailCache()

    /// Row icons are drawn at 20 pt, `scaledToFill`: the *short* edge must reach
    /// 40 px for a sharp 2× render.
    nonisolated static let rowThumbnailPixels: CGFloat = 40
    /// Upper bound on a row thumbnail's long edge, so a panorama doesn't decode
    /// at a silly size just to give its short edge 40 px.
    nonisolated static let rowThumbnailMaxLongEdge: CGFloat = 400
    /// Long-edge bound for the preview pane's image — larger than the pane can
    /// draw on any screen we size the popup for, far smaller than a 5K capture.
    nonisolated static let previewMaxPixels: CGFloat = 1600

    private let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600   // a little over ClipboardCache.maxResident
        return cache
    }()
    /// The preview pane shows one image at a time; a few entries cover
    /// arrowing back and forth between neighbours.
    private let previews: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 4
        return cache
    }()

    /// Small row thumbnail for the image at `path`; nil when unreadable.
    func thumbnail(forPath path: String) -> NSImage? {
        if let hit = thumbnails.object(forKey: path as NSString) { return hit }
        guard let image = Self.decode(path: path, maxPixels: { size in
            Self.rowThumbnailMaxPixelSize(for: size)
        }) else { return nil }
        thumbnails.setObject(image, forKey: path as NSString)
        return image
    }

    /// Preview-sized image (long edge ≤ `previewMaxPixels`); nil when unreadable.
    func fullImage(forPath path: String) -> NSImage? {
        if let hit = previews.object(forKey: path as NSString) { return hit }
        guard let image = Self.decode(path: path, maxPixels: { _ in Self.previewMaxPixels }) else { return nil }
        previews.setObject(image, forKey: path as NSString)
        return image
    }

    /// Long-edge pixel bound that gives the short edge `rowThumbnailPixels`.
    nonisolated static func rowThumbnailMaxPixelSize(for size: CGSize) -> CGFloat {
        let long = max(size.width, size.height), short = min(size.width, size.height)
        guard short > 0 else { return rowThumbnailPixels }
        return min(max(rowThumbnailPixels, rowThumbnailPixels * long / short), rowThumbnailMaxLongEdge)
    }

    /// Decodes the image at `path` downsampled so its long edge is at most the
    /// bound `maxPixels` returns for the image's pixel size (never upscaled).
    private static func decode(path: String, maxPixels: (CGSize) -> CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        let bound = min(maxPixels(CGSize(width: width, height: height)), max(width, height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(bound.rounded(.up))
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
