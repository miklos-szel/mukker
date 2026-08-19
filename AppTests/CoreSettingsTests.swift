import XCTest
import AppKit
import Carbon.HIToolbox
import HotKey
@testable import Sniptory

final class CoreSettingsTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "AppTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func solidImage(_ color: NSColor, size: Int) -> CGImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    // MARK: - CaptureSettings

    @MainActor
    func testSettingsDefaults() {
        let settings = CaptureSettings(defaults: makeDefaults())
        XCTAssertEqual(settings.saveFormat, .png)
        XCTAssertEqual(settings.afterCapture, .show)
        XCTAssertFalse(settings.downscaleRetina)
        XCTAssertEqual(settings.defaultLineWidth, 2)
        XCTAssertEqual(settings.canvasPadding, 24)
        // Auto-close after copy/save is on out of the box.
        XCTAssertTrue(settings.closeAfterCopy)
        XCTAssertTrue(settings.closeAfterSave)
        // Esc-copies-and-closes is opt-in (off by default).
        XCTAssertFalse(settings.escCopiesAndCloses)
    }

    // MARK: - ShortcutSettings (shared by the popup and the capture shortcuts)

    @MainActor
    func testShortcutDefaults() {
        let shortcuts = ShortcutSettings(defaults: makeDefaults())
        XCTAssertEqual(shortcuts.popupCombo, KeyCombo(key: .e, modifiers: [.command]))
        XCTAssertEqual(shortcuts.areaCombo, KeyCombo(key: .four, modifiers: [.command, .shift, .control]))
        XCTAssertEqual(shortcuts.fullscreenCombo, KeyCombo(key: .three, modifiers: [.command, .shift, .control]))
        XCTAssertEqual(shortcuts.scrollCombo, KeyCombo(key: .five, modifiers: [.command, .shift, .control]))
    }

    @MainActor
    func testShortcutsPersistAcrossInstances() {
        let defaults = makeDefaults()
        let first = ShortcutSettings(defaults: defaults)
        first.popupCombo = KeyCombo(key: .j, modifiers: [.command, .option])
        first.areaCombo = KeyCombo(key: .a, modifiers: [.command])

        let second = ShortcutSettings(defaults: defaults)
        XCTAssertEqual(second.popupCombo, KeyCombo(key: .j, modifiers: [.command, .option]))
        XCTAssertEqual(second.areaCombo, KeyCombo(key: .a, modifiers: [.command]))
    }

    /// Pre-merge the popup shortcut lived in its own JSON blob; upgraders must
    /// keep it rather than silently falling back to the ⌘E default.
    @MainActor
    func testLegacyPopupHotKeyIsAdopted() {
        let defaults = makeDefaults()
        // kVK_ANSI_K = 40, cmdKey | shiftKey
        let legacy = #"{"keyCode":40,"modifiers":\#(UInt32(cmdKey) | UInt32(shiftKey))}"#
        defaults.set(Data(legacy.utf8), forKey: "com.sniptory.globalHotKey")

        let shortcuts = ShortcutSettings(defaults: defaults)
        XCTAssertEqual(shortcuts.popupCombo, KeyCombo(key: .k, modifiers: [.command, .shift]))

        // Rewritten in the current format, so the legacy blob is only read once.
        XCTAssertNotNil(defaults.dictionary(forKey: "popupCombo"))
    }

    @MainActor
    func testResetToDefaultsRestoresEveryCombo() {
        let shortcuts = ShortcutSettings(defaults: makeDefaults())
        shortcuts.popupCombo = KeyCombo(key: .z, modifiers: [.control])
        shortcuts.scrollCombo = KeyCombo(key: .z, modifiers: [.control])
        shortcuts.resetToDefaults()
        XCTAssertEqual(shortcuts.popupCombo, ShortcutSettings.defaultPopupCombo)
        XCTAssertEqual(shortcuts.scrollCombo, ShortcutSettings.defaultScrollCombo)
    }

    @MainActor
    func testSettingsPersistAcrossInstances() {
        let defaults = makeDefaults()
        let first = CaptureSettings(defaults: defaults)
        first.saveFormat = .jpeg
        first.afterCapture = .copy
        first.downscaleRetina = true
        first.closeAfterCopy = false
        first.closeAfterSave = false
        first.escCopiesAndCloses = true
        first.canvasPadding = 80

        let second = CaptureSettings(defaults: defaults)
        XCTAssertEqual(second.saveFormat, .jpeg)
        XCTAssertEqual(second.afterCapture, .copy)
        XCTAssertTrue(second.downscaleRetina)
        XCTAssertFalse(second.closeAfterCopy)
        XCTAssertFalse(second.closeAfterSave)
        XCTAssertTrue(second.escCopiesAndCloses)
        XCTAssertEqual(second.canvasPadding, 80)
    }

    // MARK: - Editor tool shortcuts

    @MainActor
    func testToolKeyDefaultsToBuiltIn() {
        let settings = CaptureSettings(defaults: makeDefaults())
        XCTAssertEqual(EditorShortcuts.effective(.arrow, settings), "a")
        XCTAssertEqual(EditorShortcuts.tool(forKey: "r", settings), .roundedRectangle)
        XCTAssertEqual(EditorShortcuts.tool(forKey: "o", settings), .rectangle)
    }

    @MainActor
    func testAssignOverridesAndPersists() {
        let defaults = makeDefaults()
        let settings = CaptureSettings(defaults: defaults)
        EditorShortcuts.assign("k", to: .arrow, settings)
        XCTAssertEqual(EditorShortcuts.effective(.arrow, settings), "k")
        XCTAssertEqual(EditorShortcuts.tool(forKey: "k", settings), .arrow)

        // Persists across instances.
        let reloaded = CaptureSettings(defaults: defaults)
        XCTAssertEqual(EditorShortcuts.effective(.arrow, reloaded), "k")
    }

    @MainActor
    func testAssignDuplicateSwapsKeys() {
        let settings = CaptureSettings(defaults: makeDefaults())
        // Give the rectangle tool arrow's key 'a'; arrow should take rectangle's 'o'.
        EditorShortcuts.assign("a", to: .rectangle, settings)
        XCTAssertEqual(EditorShortcuts.effective(.rectangle, settings), "a")
        XCTAssertEqual(EditorShortcuts.effective(.arrow, settings), "o")
        // Every tool still resolves to exactly one key.
        let keys = Tool.allCases.map { EditorShortcuts.effective($0, settings) }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    @MainActor
    func testAssignIgnoresNonLetter() {
        let settings = CaptureSettings(defaults: makeDefaults())
        EditorShortcuts.assign("5", to: .arrow, settings)
        XCTAssertEqual(EditorShortcuts.effective(.arrow, settings), "a")
    }

    // MARK: - ImageExporter

    func testJPEGEncodingProducesData() {
        let image = solidImage(.blue, size: 40)
        XCTAssertNotNil(ImageExporter.data(from: image, format: .jpeg))
        XCTAssertNotNil(ImageExporter.data(from: image, format: .png))
    }

    func testDownscaleHalvesDimensionsAtScale2() {
        let image = solidImage(.red, size: 100)
        let scaled = ImageExporter.downscaled(image, by: 2)
        XCTAssertEqual(scaled.width, 50)
        XCTAssertEqual(scaled.height, 50)
    }

    func testDownscaleNoOpAtScale1() {
        let image = solidImage(.red, size: 100)
        let scaled = ImageExporter.downscaled(image, by: 1)
        XCTAssertEqual(scaled.width, 100)
    }
}
