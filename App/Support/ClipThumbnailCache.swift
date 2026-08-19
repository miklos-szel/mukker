import AppKit

/// Caches decoded images for image clip items so the popup never decodes a
/// full-size PNG during list rendering (rows previously re-read the file on
/// every render, i.e. on every arrow-key press).
///
/// Keys are file paths; image files are content-addressed (named by their
/// SHA-256), so a cached entry can never go stale — the same path always
/// holds the same bytes.
@MainActor
final class ClipThumbnailCache {
    static let shared = ClipThumbnailCache()

    /// Max thumbnail dimension in points (rows draw at 20 pt; 40 covers 2×).
    private let thumbnailDimension: CGFloat = 40

    private var thumbnails: [String: NSImage] = [:]
    /// The preview pane shows one full-size image at a time; cache just the
    /// last one so re-renders of the same selection don't re-decode.
    private var lastFullImage: (path: String, image: NSImage)?

    /// Small row thumbnail for the image at `path`; nil when unreadable.
    func thumbnail(forPath path: String) -> NSImage? {
        if let hit = thumbnails[path] { return hit }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        let thumb = downscale(image, to: thumbnailDimension)
        thumbnails[path] = thumb
        return thumb
    }

    /// Full-size image for the preview pane; nil when unreadable.
    func fullImage(forPath path: String) -> NSImage? {
        if let last = lastFullImage, last.path == path { return last.image }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        lastFullImage = (path, image)
        return image
    }

    private func downscale(_ image: NSImage, to maxDimension: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: .zero, operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }
}
