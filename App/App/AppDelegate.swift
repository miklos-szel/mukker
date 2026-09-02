import AppKit
import Combine
import SwiftUI

/// Wires every long-lived service in the app. Read this top-to-bottom to follow
/// the runtime flow: storage/caches → clipboard services → capture services →
/// keep-awake → global hotkeys → window entry points.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var snippetsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    /// The menu bar item. Retained here for the life of the app — dropping it
    /// removes the item from the menu bar.
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Sleep prevention: installs its workspace observers and honours the
        // "turn on at launch" preference. Independent of the other two feature sets.
        KeepAwakeService.shared.start()

        // One manager owns all four system-wide shortcuts. The menu items carry
        // the same key equivalents for discoverability; CaptureCoordinator's
        // in-flight guard keeps a double-trigger from starting two captures.
        // Window tiling registers only while it is switched on, so that its
        // ⌃⌘arrow combos are free for other apps when the user doesn't want it.
        let tilingEnabled = { WindowTilingSettings.shared.isEnabled }
        HotKeyManager.shared.start(
            settings: ShortcutSettings.shared,
            actions: [
                .init(combo: \.popupCombo,
                      handler: { PopupWindowController.shared.toggle() }),  // toggles: press again to close
                .init(combo: \.areaCombo, handler: { [weak self] in self?.captureArea() }),
                .init(combo: \.fullscreenCombo, handler: { [weak self] in self?.captureScreen() }),
                .init(combo: \.scrollCombo, handler: { [weak self] in self?.captureScrolling() }),
                .init(combo: \.tileLeftCombo, isEnabled: tilingEnabled,
                      handler: { [weak self] in self?.tileWindow(.left) }),
                .init(combo: \.tileRightCombo, isEnabled: tilingEnabled,
                      handler: { [weak self] in self?.tileWindow(.right) }),
                .init(combo: \.tileTopCombo, isEnabled: tilingEnabled,
                      handler: { [weak self] in self?.tileWindow(.top) }),
                .init(combo: \.tileBottomCombo, isEnabled: tilingEnabled,
                      handler: { [weak self] in self?.tileWindow(.bottom) })
            ],
            reloadOn: WindowTilingSettings.shared.$isEnabled
                .dropFirst()
                .map { _ in () }
                .eraseToAnyPublisher()
        )

        // The menu bar item, last so everything it can invoke already exists.
        menuBar = MenuBarController(actions: menuBarActions())

#if DEBUG
        if ProcessInfo.processInfo.environment["MUKKER_DUMP_MENU"] == "1", let menuBar {
            print(menuBar.debugDump())
            exit(0)
        }
#endif

        // We hide the dock icon via LSUIElement; still set activation policy as a guard
        // so windows we open can come forward.
        NSApp.setActivationPolicy(.accessory)
        Log.app.info("\(Branding.name, privacy: .public) launched")
    }

    /// Everything the menu bar can invoke. Passing closures rather than `self`
    /// keeps `MenuBarController` unaware of the delegate.
    private func menuBarActions() -> MenuBarController.Actions {
        var actions = MenuBarController.Actions(
            showPopup: { [weak self] in self?.showPopup() },
            openSnippetsManager: { [weak self] in self?.openSnippetsManager() },
            captureArea: { [weak self] in self?.captureArea() },
            captureScreen: { [weak self] in self?.captureScreen() },
            captureScrolling: { [weak self] in self?.captureScrolling() },
            openSettings: { [weak self] in self?.openSettings() })
#if DEBUG
        actions.openDebugSample = { [weak self] in self?.openDebugSample() }
#endif
        return actions
    }

    /// Release the power assertion promptly on a clean quit. (It is also
    /// self-expiring, so an unclean exit drains within the assertion timeout.)
    func applicationWillTerminate(_ notification: Notification) {
        KeepAwakeService.shared.deactivate()
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

    // MARK: - Window tiling entry point

    func tileWindow(_ slot: TileSlot) {
        WindowTiler.shared.tile(slot)
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
