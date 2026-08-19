import XCTest
@testable import AppCore

final class KeepAwakeTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "AppTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - Settings

    @MainActor
    func testDefaults() {
        let settings = KeepAwakeSettings(defaults: makeDefaults())
        // Two hours out of the box, matching the menu's "Turn On".
        XCTAssertEqual(settings.defaultDuration, .twoHours)
        XCTAssertFalse(settings.activateAtLaunch)
        XCTAssertFalse(settings.allowDisplaySleep)
        // An explicit manual sleep should win over a forgotten assertion.
        XCTAssertTrue(settings.deactivateOnManualSleep)
    }

    @MainActor
    func testSettingsPersistAcrossInstances() {
        let defaults = makeDefaults()
        let first = KeepAwakeSettings(defaults: defaults)
        first.defaultDuration = .fifteenMinutes
        first.activateAtLaunch = true
        first.allowDisplaySleep = true
        first.deactivateOnManualSleep = false

        let second = KeepAwakeSettings(defaults: defaults)
        XCTAssertEqual(second.defaultDuration, .fifteenMinutes)
        XCTAssertTrue(second.activateAtLaunch)
        XCTAssertTrue(second.allowDisplaySleep)
        XCTAssertFalse(second.deactivateOnManualSleep)
    }

    @MainActor
    func testIndefiniteDurationRoundTrips() {
        // `.indefinite` is raw value 0 — it must survive a round trip rather than
        // looking like "nothing stored" and falling back to the default.
        let defaults = makeDefaults()
        KeepAwakeSettings(defaults: defaults).defaultDuration = .indefinite
        XCTAssertEqual(KeepAwakeSettings(defaults: defaults).defaultDuration, .indefinite)
    }

    @MainActor
    func testUnknownStoredDurationFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set(4242, forKey: "keepAwakeDefaultDuration")
        XCTAssertEqual(KeepAwakeSettings(defaults: defaults).defaultDuration, .twoHours)
    }

    // MARK: - Durations

    func testDurationIntervals() {
        XCTAssertNil(KeepAwakeDuration.indefinite.interval)
        XCTAssertEqual(KeepAwakeDuration.twoHours.interval, 7200)
        XCTAssertEqual(KeepAwakeDuration.fiveMinutes.interval, 300)
        XCTAssertEqual(KeepAwakeDuration.fiveHours.interval, 18000)

        for duration in KeepAwakeDuration.allCases where duration != .indefinite {
            XCTAssertEqual(duration.interval, TimeInterval(duration.rawValue * 60), "\(duration)")
        }
        XCTAssertFalse(KeepAwakeDuration.allCases.contains { $0.label.isEmpty })
    }

    // MARK: - Countdown formatting

    func testFormatRemaining() {
        XCTAssertEqual(KeepAwakeService.format(remaining: 7080), "1h 58m")
        XCTAssertEqual(KeepAwakeService.format(remaining: 7200), "2h 0m")
        // Seconds are hidden above a minute, so a value republished up to a
        // minute late never renders as visibly wrong.
        XCTAssertEqual(KeepAwakeService.format(remaining: 3500), "58m")
        XCTAssertEqual(KeepAwakeService.format(remaining: 90), "1m")
        XCTAssertEqual(KeepAwakeService.format(remaining: 45), "45s")
        XCTAssertEqual(KeepAwakeService.format(remaining: 0), "0s")
        // Never renders a negative countdown if a read lands after the deadline.
        XCTAssertEqual(KeepAwakeService.format(remaining: -5), "0s")
    }

    // MARK: - Service state

    @MainActor
    func testActivateForFiniteDurationSetsRemaining() {
        let service = KeepAwakeService(settings: KeepAwakeSettings(defaults: makeDefaults()))
        service.activate(for: .thirtyMinutes)
        XCTAssertTrue(service.isActive)
        XCTAssertEqual(service.remaining ?? 0, 1800, accuracy: 2)
        service.deactivate()
        XCTAssertFalse(service.isActive)
        XCTAssertNil(service.remaining)
    }

    @MainActor
    func testActivateIndefinitelyHasNoRemaining() {
        let service = KeepAwakeService(settings: KeepAwakeSettings(defaults: makeDefaults()))
        service.activate(for: .indefinite)
        XCTAssertTrue(service.isActive)
        XCTAssertNil(service.remaining)
        XCTAssertEqual(service.statusText, "On — until turned off")
        service.deactivate()
    }

    @MainActor
    func testToggleUsesDefaultDuration() {
        let settings = KeepAwakeSettings(defaults: makeDefaults())
        settings.defaultDuration = .oneHour
        let service = KeepAwakeService(settings: settings)

        service.toggle()
        XCTAssertTrue(service.isActive)
        XCTAssertEqual(service.remaining ?? 0, 3600, accuracy: 2)

        service.toggle()
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(service.statusText, "Off")
    }
}
