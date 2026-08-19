import AppKit
import ScreenCaptureKit

/// A frozen, full-resolution capture of a single display, paired with the
/// `NSScreen` it belongs to so the overlay can be positioned in screen points.
struct DisplayCapture {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    /// Full-resolution pixels of the display.
    let image: CGImage
    /// Backing scale (pixels per point) of the display.
    let scale: CGFloat
}

enum ScreenCaptureError: Error {
    case noDisplays
    case displayNotFound
}

/// Captures displays as still images via ScreenCaptureKit (macOS 14+).
@MainActor
final class ScreenCaptureService {
    static let shared = ScreenCaptureService()

    /// Capture every active display. Call this *before* showing any overlay so
    /// the overlay windows are not part of the captured image.
    func captureAllDisplays() async throws -> [DisplayCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard !content.displays.isEmpty else { throw ScreenCaptureError.noDisplays }

        var results: [DisplayCapture] = []
        for display in content.displays {
            guard let screen = screen(for: display.displayID) else { continue }
            let image = try await captureImage(of: display, on: screen)
            results.append(
                DisplayCapture(
                    screen: screen,
                    displayID: display.displayID,
                    image: image,
                    scale: screen.backingScaleFactor
                )
            )
        }
        guard !results.isEmpty else { throw ScreenCaptureError.displayNotFound }
        return results
    }

    /// Capture only the display that currently contains the mouse cursor.
    func captureDisplayWithMouse() async throws -> DisplayCapture {
        let all = try await captureAllDisplays()
        let mouse = NSEvent.mouseLocation
        return all.first { NSMouseInRect(mouse, $0.screen.frame, false) } ?? all[0]
    }

    /// A reusable region capturer for one display — fetches the `SCDisplay` once
    /// so repeated grabs (scrolling capture) don't re-query shareable content.
    struct RegionCapturer {
        let filter: SCContentFilter

        /// Capture `sourceRect` (display points, top-left origin) at `pixelSize`.
        func capture(sourceRect: CGRect, pixelSize: CGSize) async throws -> CGImage {
            let config = SCStreamConfiguration()
            config.sourceRect = sourceRect
            config.width = Int(pixelSize.width)
            config.height = Int(pixelSize.height)
            config.showsCursor = false
            config.captureResolution = .best
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    /// Build a region capturer for the given display id.
    func regionCapturer(displayID: CGDirectDisplayID) async throws -> RegionCapturer {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.displayNotFound
        }
        return RegionCapturer(filter: SCContentFilter(display: display, excludingWindows: []))
    }

    private func captureImage(of display: SCDisplay, on screen: NSScreen) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? CGDirectDisplayID) == displayID
        }
    }
}
