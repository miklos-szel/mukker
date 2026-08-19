import AppKit

/// Orchestrates a capture: permission → freeze displays → (area selection) → crop
/// → hand the resulting image to whoever opens the editor.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    /// Set by the app layer to open the editor for a finished capture.
    /// Provides the captured image and its source scale (pixels per point).
    var onCapture: ((CGImage, CGFloat) -> Void)?

    private let overlay = SelectionOverlayController()
    private var isCapturing = false

    /// Drag-to-select an area on the display under the cursor.
    func captureArea() {
        beginCapture(area: true)
    }

    /// Capture the entire display under the cursor.
    func captureScreen() {
        beginCapture(area: false)
    }

    private func beginCapture(area: Bool) {
        guard !isCapturing else { return }
        guard ensurePermission() else { return }
        isCapturing = true

        Task {
            do {
                if area {
                    let captures = try await ScreenCaptureService.shared.captureAllDisplays()
                    // The guard must stay up until the user finishes (or cancels)
                    // the selection, so reset it in the completion — not when this
                    // Task ends, which is the moment the overlays appear.
                    overlay.present(captures: captures) { [weak self] result in
                        guard let self else { return }
                        self.isCapturing = false
                        guard let (capture, pixelRect) = result,
                              let cropped = capture.image.cropping(to: pixelRect) else { return }
                        self.deliver(cropped, scale: capture.scale)
                    }
                } else {
                    defer { isCapturing = false }
                    let capture = try await ScreenCaptureService.shared.captureDisplayWithMouse()
                    deliver(capture.image, scale: capture.scale)
                }
            } catch {
                Log.capture.error("capture failed: \(error.localizedDescription, privacy: .public)")
                isCapturing = false
            }
        }
    }

    private func deliver(_ image: CGImage, scale: CGFloat) {
        Log.capture.info("captured \(image.width)×\(image.height)px")
        if let onCapture {
            onCapture(image, scale)
        } else {
            Log.capture.error("no onCapture handler set")
        }
    }

    /// Returns true if Screen Recording is granted (prompting/guiding if not).
    private func ensurePermission() -> Bool {
        PermissionsService.shared.ensureScreenRecording()
    }
}
