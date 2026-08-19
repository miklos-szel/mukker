import AppKit
import SwiftUI

/// Wires every long-lived service in the app. Read this top-to-bottom to follow
/// the runtime flow: legacy migration → storage/caches → clipboard services →
/// capture services → global hotkeys → window entry points.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var snippetsWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Must run before anything touches the database or the settings objects.
        LegacyDataMigrator.runIfNeeded()

        // Ensure DB is created early, then pre-warm the caches so the popup opens
        // instantly (zero DB hits per popup after launch).
        _ = AppDatabase.shared
        SnippetCache.shared.loadAll()
        ClipboardCache.shared.loadAll()

        // The popup is a non-activating panel, so ⌘, never reaches the app menu —
        // let it open Settings directly.
        PopupWindowController.shared.onRequestSettings = { [weak self] in
            self?.openSettings()
        }

        // Clipboard capture, retention sweeping, double-⌘C fast-append merging.
        ClipboardMonitor.shared.start()
        ClipboardRetentionService.shared.start()
        FastAppendService.shared.start()

        // Capture routing: area/screen captures follow the "After screenshot"
        // setting; scrolling captures always open in the editor (a composed,
        // tall image).
        CaptureCoordinator.shared.onCapture = { image, scale in
            Self.handleCapture(image: image, scale: scale)
        }
        ScrollingCaptureService.shared.onComplete = { image, scale in
            EditorWindowController.shared.open(image: image, sourceScale: scale)
        }

        // One manager owns all four system-wide shortcuts. The menu items carry
        // the same key equivalents for discoverability; CaptureCoordinator's
        // in-flight guard keeps a double-trigger from starting two captures.
        HotKeyManager.shared.start(
            settings: ShortcutSettings.shared,
            popup: { PopupWindowController.shared.toggle() },   // toggles: press again to close
            area: { [weak self] in self?.captureArea() },
            screen: { [weak self] in self?.captureScreen() },
            scroll: { [weak self] in self?.captureScrolling() }
        )

        // We hide the dock icon via LSUIElement; still set activation policy as a guard
        // so windows we open can come forward.
        NSApp.setActivationPolicy(.accessory)
        Log.app.info("\(Branding.name, privacy: .public) launched")
    }

    // MARK: - Clipboard & snippets entry points

    func showPopup() {
        PopupWindowController.shared.show()
    }

    func openSnippetsManager() {
        if let w = snippetsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SnippetsManagerView())
        let window = EscClosableWindow(contentViewController: host)
        window.title = "Snippets"
        window.setContentSize(NSSize(width: 960, height: 600))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        snippetsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Capture entry points

    func captureArea() {
        CaptureCoordinator.shared.captureArea()
    }

    func captureScreen() {
        CaptureCoordinator.shared.captureScreen()
    }

    func captureScrolling() {
        ScrollingCaptureService.shared.capture()
    }

    /// Routes a finished capture according to the user's "After screenshot" setting.
    private static func handleCapture(image: CGImage, scale: CGFloat) {
        let settings = CaptureSettings.shared
        switch settings.afterCapture {
        case .show:
            EditorWindowController.shared.open(image: image, sourceScale: scale)
        case .copy:
            ImageExporter.copyToPasteboard(image)
        case .save:
            let output = settings.downscaleRetina
                ? ImageExporter.downscaled(image, by: scale) : image
            ImageExporter.saveSilently(output, to: settings.saveDirectory, format: settings.saveFormat)
        }
    }

    // MARK: - Settings

    func openSettings() {
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: host)
        window.title = "\(Branding.name) Settings"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

#if DEBUG
    /// Opens the editor with a generated test image — lets us exercise the editor
    /// without Screen Recording permission.
    func openDebugSample() {
        let vm = EditorWindowController.shared.open(image: Self.sampleImage(), sourceScale: 2.0)
        // Seed one of each annotation kind to verify rendering + flatten.
        var style = AnnotationStyle()
        vm.annotations = [
            Annotation(kind: .rectangle, rect: CGRect(x: 40, y: 40, width: 160, height: 90), style: style),
            Annotation(kind: .roundedRectangle, rect: CGRect(x: 220, y: 40, width: 160, height: 90),
                       style: { style.color = .yellow; return style }()),
            Annotation(kind: .ellipse, rect: CGRect(x: 400, y: 40, width: 120, height: 90),
                       style: { style.color = .green; return style }()),
            Annotation(kind: .highlight, rect: CGRect(x: 40, y: 160, width: 200, height: 40),
                       style: { style.color = .yellow; return style }()),
            Annotation(kind: .arrow, points: [CGPoint(x: 280, y: 220), CGPoint(x: 420, y: 160)],
                       style: { style.color = .red; return style }()),
            Annotation(kind: .line, points: [CGPoint(x: 40, y: 240), CGPoint(x: 240, y: 260)],
                       style: { style.color = .blue; return style }()),
            Annotation(kind: .freehand,
                       points: (0...20).map { i in
                           CGPoint(x: 300 + Double(i) * 6, y: 300 + 20 * sin(Double(i) / 2))
                       },
                       style: { style.color = .purple; return style }()),
            Annotation(kind: .text, rect: CGRect(x: 40, y: 300, width: 200, height: 40), text: "Hello",
                       style: { style.color = .white; style.fontSize = 28; return style }()),
            Annotation(kind: .counter, rect: CGRect(x: 480, y: 280, width: 44, height: 44), number: 1,
                       style: { style.color = .red; return style }())
        ]
    }

    private static func sampleImage() -> CGImage {
        let size = CGSize(width: 1200, height: 800)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let gradient = NSGradient(colors: [NSColor.systemTeal, NSColor.systemIndigo])!
        gradient.draw(in: NSRect(origin: .zero, size: size), angle: 45)
        let text = "\(Branding.name) test canvas" as NSString
        text.draw(at: NSPoint(x: 60, y: 60), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 48),
            .foregroundColor: NSColor.white
        ])
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }
#endif
}

/// A titled window that closes on Esc (consistent with the popup). Esc still
/// cancels an in-progress text-field edit first; pressing it again closes.
final class EscClosableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
