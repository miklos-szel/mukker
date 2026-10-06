import XCTest
@testable import AppCore

final class BandwidthTests: XCTestCase {
    private let hu = Locale(identifier: "hu_HU")
    private let us = Locale(identifier: "en_US")

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AppTests-\(UUID().uuidString)")!
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2   // Monday
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    // MARK: - Menu bar rate

    func testMenuBarPartsMatchesReferenceLook() {
        let parts = BandwidthFormat.menuBarParts(down: 1.1e6, up: 0.3e6, locale: hu)
        XCTAssertEqual(parts.down, "↓1,1")
        XCTAssertEqual(parts.up, "↑0,3")
        XCTAssertEqual(parts.unit, "Mbps")
    }

    func testUnitFollowsTheLargerRate() {
        XCTAssertEqual(BandwidthFormat.menuBarParts(down: 850e3, up: 12e3, locale: us).unit, "Kbps")
        XCTAssertEqual(BandwidthFormat.menuBarParts(down: 10e3, up: 2.5e6, locale: us).unit, "Mbps")
        XCTAssertEqual(BandwidthFormat.menuBarParts(down: 1.2e9, up: 0, locale: us).unit, "Gbps")
    }

    func testNumbersStayWithinThreeDigits() {
        // Just under a unit boundary rounds up into the next unit, not "1000".
        let edge = BandwidthFormat.menuBarParts(down: 999.8e3, up: 0, locale: us)
        XCTAssertEqual(edge.unit, "Mbps")
        XCTAssertEqual(edge.down, "↓1.0")
        let whole = BandwidthFormat.menuBarParts(down: 41e3, up: 137e3, locale: us)
        XCTAssertEqual(whole.down, "↓41")
        XCTAssertEqual(whole.up, "↑137")
        XCTAssertEqual(BandwidthFormat.menuBarParts(down: 0, up: 0, locale: us).down, "↓0.0")
    }

    // MARK: - Totals table

    func testVolumePartsShareTheTotalsUnit() {
        let parts = BandwidthFormat.volumeParts(received: 870_000_000, sent: 270_000_000, locale: hu)
        XCTAssertEqual(parts.received, "0,87")
        XCTAssertEqual(parts.sent, "0,27")
        XCTAssertEqual(parts.total, "1,14 GB")
        XCTAssertEqual(BandwidthFormat.volumeParts(received: 500, sent: 12, locale: us).total, "512 B")
    }

    // MARK: - Counters

    func testDeltaHandlesCounterReset() {
        XCTAssertEqual(NetworkCounters.delta(previous: 100, current: 150), 50)
        XCTAssertEqual(NetworkCounters.delta(previous: 5_000, current: 120), 120)
        XCTAssertEqual(NetworkCounters.delta(previous: .max - 1, current: .max), 1)
    }

    // MARK: - Aggregation

    func testTotalsPerPeriod() {
        let c = InterfaceCounters(received: 10, sent: 1)
        let days: BandwidthUsageStore.Days = [
            "2026-09-30": ["en0": c],               // last month, same week (Mon 28 Sep)
            "2026-10-05": ["en0": c, "en5": c],     // Monday this week
            "2026-10-06": ["en0": c],               // today (Tue)
        ]
        let now = date(2026, 10, 6)
        XCTAssertEqual(BandwidthUsageStore.totals(for: .today, in: days, now: now, calendar: utc),
                       ["en0": c])
        let week = BandwidthUsageStore.totals(for: .thisWeek, in: days, now: now, calendar: utc)
        XCTAssertEqual(week["en0"], InterfaceCounters(received: 20, sent: 2))
        XCTAssertEqual(week["en5"], c)
        let month = BandwidthUsageStore.totals(for: .thisMonth, in: days, now: now, calendar: utc)
        XCTAssertEqual(month["en0"], InterfaceCounters(received: 20, sent: 2))
        XCTAssertEqual(BandwidthUsageStore.totals(for: .thisWeek, in: days, now: date(2026, 10, 1),
                                                  calendar: utc)["en0"],
                       c)
    }

    func testPruneDropsOldDays() {
        let c = InterfaceCounters(received: 1, sent: 1)
        let days: BandwidthUsageStore.Days = ["2026-01-01": ["en0": c], "2026-10-01": ["en0": c]]
        let pruned = BandwidthUsageStore.pruned(days, now: date(2026, 10, 6), calendar: utc)
        XCTAssertEqual(Array(pruned.keys), ["2026-10-01"])
    }

    @MainActor
    func testStoreAccumulatesAndPersists() {
        let defaults = makeDefaults()
        let store = BandwidthUsageStore(defaults: defaults)
        let now = date(2026, 10, 6)
        store.add(["en0": InterfaceCounters(received: 5, sent: 2)], at: now, calendar: utc)
        store.add(["en0": InterfaceCounters(received: 5, sent: 2)], at: now, calendar: utc)
        store.flush(now: now, calendar: utc)

        let reloaded = BandwidthUsageStore(defaults: defaults)
        XCTAssertEqual(reloaded.totals(for: .today, now: now, calendar: utc)["en0"],
                       InterfaceCounters(received: 10, sent: 4))
        reloaded.reset()
        XCTAssertTrue(BandwidthUsageStore(defaults: defaults).days.isEmpty)
    }

    // MARK: - Settings

    @MainActor
    func testSettingsDefaultsAndPersistence() {
        let defaults = makeDefaults()
        let settings = BandwidthSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertTrue(settings.showsInMenuBar)
        XCTAssertEqual(settings.shownPeriods, [.today])
        XCTAssertEqual(settings.refreshInterval, 5)

        settings.setShows(.thisMonth, true)
        settings.setShows(.today, false)
        settings.refreshInterval = 2
        let reloaded = BandwidthSettings(defaults: defaults)
        XCTAssertEqual(reloaded.shownPeriods, [.thisMonth])
        XCTAssertEqual(reloaded.refreshInterval, 2)
    }
}
