import AppKit
import UniformTypeIdentifiers

/// Flattens / encodes images and sends them to the clipboard or disk.
enum ImageExporter {
    static func nsImage(from cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Encode a bitmap as PNG or JPEG.
    static func data(from cg: CGImage, format: SaveFormat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: cg.width, height: cg.height)
        switch format {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .jpeg:
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    static func pngData(from cg: CGImage) -> Data? {
        data(from: cg, format: .png)
    }

    /// Downsample by an integer-ish factor (e.g. 2 for a retina capture → 1×).
    /// Returns the original when `factor <= 1`.
    static func downscaled(_ cg: CGImage, by factor: CGFloat) -> CGImage {
        guard factor > 1 else { return cg }
        let width = Int((CGFloat(cg.width) / factor).rounded())
        let height = Int((CGFloat(cg.height) / factor).rounded())
        guard width > 0, height > 0,
              let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? cg
    }

    /// Copy a bitmap image to the general pasteboard as PNG (with a TIFF fallback).
    static func copyToPasteboard(_ cg: CGImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        if let png = pngData(from: cg) { pb.setData(png, forType: .png) }
        if let tiff = nsImage(from: cg).tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        Log.export.info("copied \(cg.width)×\(cg.height)px to pasteboard")
    }

    /// Save without prompting, to `directory` using a timestamped name.
    @discardableResult
    static func saveSilently(_ cg: CGImage, to directory: URL, format: SaveFormat) -> URL? {
        guard let data = data(from: cg, format: format) else { return nil }
        let url = directory.appendingPathComponent(
            AppPaths.suggestedFileName(fileExtension: format.fileExtension))
        do {
            try data.write(to: url)
            Log.export.info("saved \(format.label) to \(url.path, privacy: .public)")
            return url
        } catch {
            Log.export.error("save failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Present a save panel for the given format, defaulting to `directory`.
    @MainActor
    @discardableResult
    static func savePanel(_ cg: CGImage, format: SaveFormat, directory: URL) -> URL? {
        guard let data = data(from: cg, format: format) else { return nil }
        let type: UTType = format == .png ? .png : .jpeg
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = AppPaths.suggestedFileName(fileExtension: format.fileExtension)
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try data.write(to: url)
            Log.export.info("saved \(format.label) to \(url.path, privacy: .public)")
            return url
        } catch {
            Log.export.error("save failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
