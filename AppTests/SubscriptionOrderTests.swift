import XCTest
import AppKit
import Combine
import HotKey
@testable import AppCore

/// `@Published` emits from `willSet`, so a sink that re-reads the property sees
/// the old value. These cover the subscriptions that used to fall into that.
final class SubscriptionOrderTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AppTests-\(UUID().uuidString)")!
    }

    /// Lets one pass of the main run loop run, which is where
    /// `receive(on: RunLoop.main)` delivers.
    private func spinRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: - Shortcut recorder

    func testComboWithoutModifierIsRejected() {
        XCTAssertFalse(ShortcutRecorderField.isAcceptable(KeyCombo(key: .f)))
        XCTAssertFalse(ShortcutRecorderField.isAcceptable(KeyCombo(key: .leftArrow)))
        XCTAssertFalse(ShortcutRecorderField.isAcceptable(KeyCombo(key: .space)))
    }

    func testShiftAloneIsNotEnough() {
        XCTAssertFalse(ShortcutRecorderField.isAcceptable(KeyCombo(key: .f, modifiers: [.shift])))
    }

    func testComboWithCommandControlOrOptionIsAccepted() {
        XCTAssertTrue(ShortcutRecorderField.isAcceptable(KeyCombo(key: .e, modifiers: [.command])))
        XCTAssertTrue(ShortcutRecorderField.isAcceptable(KeyCombo(key: .leftArrow, modifiers: [.control, .command])))
        XCTAssertTrue(ShortcutRecorderField.isAcceptable(KeyCombo(key: .f, modifiers: [.option, .shift])))
    }

    func testBareFunctionKeysAreAccepted() {
        XCTAssertTrue(ShortcutRecorderField.isAcceptable(KeyCombo(key: .f1)))
        XCTAssertTrue(ShortcutRecorderField.isAcceptable(KeyCombo(key: .f13)))
        XCTAssertTrue(ShortcutRecorderField.isAcceptable(KeyCombo(key: .f20)))
    }

    // MARK: - Hotkey reload timing

    /// Mirrors `HotKeyManager.start`: a `comboChanges` sink that re-reads the
    /// settings must see the newly recorded combo, not the one it replaced.
    @MainActor
    func testComboChangesDeliveredOnRunLoopSeeTheNewCombo() {
        let settings = ShortcutSettings(defaults: makeDefaults())
        let recorded = KeyCombo(key: .k, modifiers: [.command, .option])
        XCTAssertNotEqual(settings.popupCombo, recorded)

        var seen: [KeyCombo] = []
        let cancellable = settings.comboChanges
            .receive(on: RunLoop.main)
            .sink { seen.append(settings.popupCombo) }

        settings.popupCombo = recorded
        spinRunLoop()

        XCTAssertEqual(seen, [recorded])
        cancellable.cancel()
    }

    // MARK: - Bandwidth sampling

    @MainActor
    func testBandwidthSamplingRestartsAfterOffThenOn() {
        let defaults = makeDefaults()
        let settings = BandwidthSettings(defaults: defaults)
        let service = BandwidthService(settings: settings, store: BandwidthUsageStore(defaults: defaults))

        service.start()
        XCTAssertTrue(service.isSampling)

        settings.isEnabled = false
        XCTAssertFalse(service.isSampling)

        settings.isEnabled = true
        XCTAssertTrue(service.isSampling, "re-enabling must re-arm the sampling timer")

        // A new interval re-arms a running timer, and does not start a stopped one.
        settings.refreshInterval = 2
        XCTAssertTrue(service.isSampling)
        settings.isEnabled = false
        settings.refreshInterval = 3
        XCTAssertFalse(service.isSampling)
    }
}
