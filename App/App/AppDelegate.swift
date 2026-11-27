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
    private(set) var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure DB is created early, then pre-warm the caches so the popup opens
        // instantly (zero DB hits per popup after launch).
        _ = AppDatabase.shared
        SnippetCache.shared.loadAll()
        ClipboardCache.shared.loadAll()

        // Launch housekeeping, off the main thread (it walks the support folder):
        // owner-only permissions on the history, then delete sidecar files no row
        // references. The sweep is safe against captures running meanwhile — see
        // `ClipboardRepository.removeOrphanedSidecarFiles`.
        DispatchQueue.global(qos: .utility).async {
            let tightened = AppPaths.tightenPermissions(under: AppPaths.supportDirectory)
            if tightened > 0 {
                Log.clipboard.info("Restricted permissions on \(tightened) support item(s)")
            }
            do {
                let removed = try ClipboardRepository().removeOrphanedSidecarFiles(
                    in: [AppPaths.imagesDirectory, AppPaths.richTextDirectory])
                Log.clipboard.info("Orphan sweep removed \(removed) sidecar file(s)")
            } catch {
                Log.clipboard.error("Orphan sweep failed: \(error.localizedDescription)")
            }
        }

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
        HourlyChimeService.shared.start()

        // Bandwidth monitor: samples the network interfaces every refresh
        // interval (5 s by default, 1–30 s in Settings) for the menu bar rate
        // and the per-interface daily totals.
        BandwidthService.shared.start()

        // Razer mouse battery: polls a connected wireless Viper over USB for the
        // menu's Mouse submenu and its low-battery warning row.
        MouseBatteryService.shared.start()

        // Dictation: the fn/right-⌥ key monitor, the recording/transcribing
        // coordinator and its on-screen pill. Its custom-shortcut variant is a
        // hotkey below. A missing model sends the user to its settings tab.
        DictationService.shared.onRequestSettings = { [weak self] in self?.openSettings(tab: .dictation) }
        DictationService.shared.start()
        DictationOverlayController.shared.start()

        // One manager owns every system-wide shortcut. The menu items carry
        // the same key equivalents for discoverability; CaptureCoordinator's
        // in-flight guard keeps a double-trigger from starting two captures.
        // Window tiling registers only while it is switched on, so that its
        // ⌃⌘arrow combos are free for other apps when the user doesn't want it.
        let tilingEnabled = { WindowTilingSettings.shared.isEnabled }
        // Translation likewise frees ⌘⇧E/⌘⌥E while it is switched off.
        let translationEnabled = { TranslationSettings.shared.isEnabled }
        // The dictation combo exists only while the trigger is "Custom shortcut".
        let dictationComboEnabled = {
            DictationSettings.shared.isEnabled && DictationSettings.shared.trigger == .combo
        }
        // The per-language dictation combos need the opt-in and a model that takes a hint.
        let dictationLanguageEnabled = {
            let settings = DictationSettings.shared
            return settings.isEnabled && settings.languageShortcutsEnabled && settings.model.honoursLanguage
        }
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
                      handler: { [weak self] in self?.tileWindow(.bottom) }),
                .init(combo: \.translateEnglishCombo, isEnabled: translationEnabled,
                      handler: { [weak self] in self?.translateSelectionOrLatest(.english) }),
                .init(combo: \.translateHungarianCombo, isEnabled: translationEnabled,
                      handler: { [weak self] in self?.translateSelectionOrLatest(.hungarian) }),
                .init(combo: \.translateGermanCombo, isEnabled: translationEnabled,
                      handler: { [weak self] in self?.translateSelectionOrLatest(.german) }),
                .init(combo: \.translateAutoCombo, isEnabled: translationEnabled,
                      handler: { [weak self] in self?.translateSelectionOrLatest(nil) }),
                .init(combo: \.dictationCombo, isEnabled: dictationComboEnabled,
                      handler: { DictationService.shared.press() },
                      releaseHandler: { DictationService.shared.release() }),
                .init(combo: \.dictationEnglishCombo, isEnabled: dictationLanguageEnabled,
                      handler: { DictationService.shared.press(language: .english) },
                      releaseHandler: { DictationService.shared.release() }),
                .init(combo: \.dictationGermanCombo, isEnabled: dictationLanguageEnabled,
                      handler: { DictationService.shared.press(language: .german) },
                      releaseHandler: { DictationService.shared.release() }),
                .init(combo: \.dictationHungarianCombo, isEnabled: dictationLanguageEnabled,
                      handler: { DictationService.shared.press(language: .hungarian) },
                      releaseHandler: { DictationService.shared.release() })
            ],
            // Any of these switches re-registers. Each drops its subscribe-time
            // replay; the manager delivers on the run loop, after the new value is stored.
            reloadOn: Publishers.MergeMany(
                WindowTilingSettings.shared.$isEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                TranslationSettings.shared.$isEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                DictationSettings.shared.$isEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                DictationSettings.shared.$trigger.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                DictationSettings.shared.$languageShortcutsEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                DictationSettings.shared.$modelID.dropFirst().map { _ in () }.eraseToAnyPublisher()
            )
            .eraseToAnyPublisher()
        )

        // The menu bar item, last so everything it can invoke already exists.
        menuBar = MenuBarController(actions: menuBarActions())

        // The app has no Dock icon and no main menu, so the menu bar menu can
        // only be reached by clicking the status item. These two hooks are how a
        // build gets screenshotted or diffed without a human doing that.
#if DEBUG
        if ProcessInfo.processInfo.environment["MUKKER_OPEN_MENU"] == "1" {
            // A run-loop timer, not a dispatch block: NSMenu tracking does not
            // drain the main dispatch queue, so anything queued that way would
            // only run once the menu closes again.
            let timer = Timer(timeInterval: 1.5, repeats: false) { _ in
                MainActor.assumeIsolated { self.menuBar?.debugOpenMenu() }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        if ProcessInfo.processInfo.environment["MUKKER_DUMP_MENU"] == "1", let menuBar {
            print(menuBar.debugDump())
            exit(0)
        }
        // Same reason: the editor is only reachable by taking a real capture, so
        // its chrome can't otherwise be screenshotted from a script. Reuses the
        // existing `openDebugSample()` so both paths show the same test canvas.
        if ProcessInfo.processInfo.environment["MUKKER_OPEN_EDITOR"] == "1" {
            openDebugSample()
        }
        // Settings on a given tab (`MUKKER_OPEN_SETTINGS=network`) and the popup
        // — again only reachable by a human otherwise. Used for README screenshots.
        if let name = ProcessInfo.processInfo.environment["MUKKER_OPEN_SETTINGS"] {
            openSettings(tab: SettingsTab(rawValue: name) ?? .clipboard)
        }
        if ProcessInfo.processInfo.environment["MUKKER_OPEN_POPUP"] == "1" {
            let timer = Timer(timeInterval: 1.0, repeats: false) { _ in
                MainActor.assumeIsolated { PopupWindowController.shared.show() }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        // The translate panel on the selection or newest history entry
        // (`MUKKER_TRANSLATE=en|hu|de|auto`), after the cache has loaded — the
        // hotkey is otherwise the only way in.
        if let code = ProcessInfo.processInfo.environment["MUKKER_TRANSLATE"],
           code == "auto" || TranslationLanguage(shortCode: code) != nil {
            let language = TranslationLanguage(shortCode: code)
            let timer = Timer(timeInterval: 1.0, repeats: false) { _ in
                MainActor.assumeIsolated { self.translateSelectionOrLatest(language) }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        // Transcribes a WAV through the selected model and logs the result
        // (`MUKKER_DICTATE_FILE=/path/to.wav`) — the engine without a microphone.
        if let path = ProcessInfo.processInfo.environment["MUKKER_DICTATE_FILE"] {
            debugTranscribe(path: path)
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
        actions.translateToEnglish = { [weak self] in self?.translateSelectionOrLatest(.english) }
        actions.translateToHungarian = { [weak self] in self?.translateSelectionOrLatest(.hungarian) }
        actions.translateToGerman = { [weak self] in self?.translateSelectionOrLatest(.german) }
        actions.translateAutomatically = { [weak self] in self?.translateSelectionOrLatest(nil) }
        actions.openDictationSettings = { [weak self] in self?.openSettings(tab: .dictation) }
#if DEBUG
        actions.openDebugSample = { [weak self] in self?.openDebugSample() }
#endif
        return actions
    }

    /// Release the power assertion promptly on a clean quit. (It is also
    /// self-expiring, so an unclean exit drains within the assertion timeout.)
    func applicationWillTerminate(_ notification: Notification) {
        KeepAwakeService.shared.deactivate()
        // Totals are otherwise only written once a minute.
        BandwidthService.shared.flush()
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

    // MARK: - Translation entry point

    /// Translates the text selected in the focused app, else the newest text in
    /// the clipboard history; pressing the same language's hotkey again while
    /// the panel is up closes it. The panel controller reads the selection
    /// before it shows anything, so nothing here may take focus first.
    /// A nil `language` translates into the default target for the detected
    /// source language.
    func translateSelectionOrLatest(_ language: TranslationLanguage?) {
        TranslationPanelController.shared.show(language: language)
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
            let directory = settings.saveDirectory
            if case .failure(let error) = ImageExporter.saveSilently(output, to: directory,
                                                                     format: settings.saveFormat) {
                // Keep the capture: open it in the editor (full resolution, as for
                // "show"), then say why the save didn't happen.
                EditorWindowController.shared.open(image: image, sourceScale: scale)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn't save the screenshot"
                alert.informativeText = "\(Branding.name) couldn't save to “\(directory.path)”: "
                    + "\(error.localizedDescription)\n\nThe capture is open in the editor instead."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    // MARK: - Settings

    func openSettings(tab: SettingsTab? = nil) {
        if let w = settingsWindow {
            // A specific tab was asked for (e.g. "Dictation Settings…"): swap in a
            // fresh root on that tab — the old view's @State selection would
            // otherwise win.
            if let tab, let host = w.contentViewController as? NSHostingController<SettingsView> {
                host.rootView = SettingsView(selection: tab)
            }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SettingsView(selection: tab ?? .clipboard))
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
    /// Reads a WAV (any format AVAudioFile can open), converts to 16 kHz mono
    /// and prints the transcript to stdout. Debug only — the one place a
    /// transcript is ever written anywhere.
    private func debugTranscribe(path: String) {
        guard let samples = DebugAudio.load(path) else {
            print("MUKKER_DICTATE_FILE: couldn't read \(path)")
            return
        }
        let settings = DictationSettings.shared
        let plan = DictationLanguagePlan.plan(model: settings.model, selected: settings.language,
                                              preferred: settings.preferredLanguages)
        print("MUKKER_DICTATE_FILE: \(samples.count) samples, model \(settings.model.id), plan \(plan)")
        TranscriptionEngine.shared.transcribe(samples, model: settings.model, plan: plan) { outcome in
            switch outcome {
            case .success(let result): print("MUKKER_DICTATE_FILE [\(result.language ?? "?")]: \(result.text)")
            case .failure(let error): print("MUKKER_DICTATE_FILE failed: \(error)")
            }
            fflush(stdout)   // a pipe is block-buffered; the run is killed afterwards
        }
    }

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
