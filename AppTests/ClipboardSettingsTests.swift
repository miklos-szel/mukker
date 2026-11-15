import XCTest
@testable import AppCore

@MainActor
final class ClipboardSettingsTests: XCTestCase {

    private func makeSettings() -> (ClipboardSettings, UserDefaults) {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (ClipboardSettings(defaults: defaults), defaults)
    }

    func testDefaults() {
        let (s, _) = makeSettings()
        XCTAssertTrue(s.keepText)
        XCTAssertTrue(s.keepImages)
        XCTAssertTrue(s.keepFiles)
        XCTAssertEqual(s.textRetention, .month)
        XCTAssertTrue(s.moveToTopOnUse)
        XCTAssertFalse(s.fastAppendEnabled)
        XCTAssertEqual(s.appendSeparator, .space)
        XCTAssertEqual(s.maxClipSize, .k256)
        XCTAssertEqual(s.maxHistoryItems, 1000)
        XCTAssertTrue(s.autoPasteEnabled)
        XCTAssertFalse(s.foreverHistoryEnabled)
        XCTAssertFalse(s.foreverHistoryDirectory.isEmpty)
    }

    func testMaxHistoryAndAutoPastePersist() {
        let (s, _) = makeSettings()
        s.maxHistoryItems = 250
        s.autoPasteEnabled = false
        XCTAssertEqual(s.maxHistoryItems, 250)
        XCTAssertFalse(s.autoPasteEnabled)
    }

    func testTogglePersists() {
        let (s, _) = makeSettings()
        s.keepText = false
        XCTAssertFalse(s.keepText)
        XCTAssertFalse(s.isKindEnabled(.text))
        XCTAssertTrue(s.isKindEnabled(.image))
    }

    func testRetentionPerKind() {
        let (s, _) = makeSettings()
        s.imageRetention = .week
        XCTAssertEqual(s.retention(for: .image), .week)
        XCTAssertEqual(s.retention(for: .text), .month)
    }

    func testIgnoredAppsRoundTripAndReset() {
        let (s, _) = makeSettings()
        let defaultCount = s.ignoredApps.count
        s.ignoredApps = s.ignoredApps + [IgnoredApp(bundleID: "com.example.app", displayName: "Example")]
        XCTAssertTrue(s.ignoredBundleIDs.contains("com.example.app"))
        s.resetIgnoredApps()
        XCTAssertEqual(s.ignoredApps.count, defaultCount)
        XCTAssertFalse(s.ignoredBundleIDs.contains("com.example.app"))
    }

    func testDecodedListsFollowSettersAndExternalWrites() throws {
        let (s, defaults) = makeSettings()
        XCTAssertEqual(s.ignoredApps, ClipboardSettings.defaultIgnoredApps)
        XCTAssertTrue(s.ignoredBundleIDs.contains("com.apple.keychainaccess"))

        s.ignoredApps = [IgnoredApp(bundleID: "com.example.a", displayName: "A")]
        XCTAssertEqual(s.ignoredBundleIDs, ["com.example.a"])
        XCTAssertEqual(s.ignoredApps.map(\.bundleID), ["com.example.a"])

        // A write that bypasses the setter is still seen.
        let data = try JSONEncoder().encode([IgnoredApp(bundleID: "com.example.b", displayName: "B")])
        defaults.set(data, forKey: "clip.ignoredApps")
        XCTAssertEqual(s.ignoredBundleIDs, ["com.example.b"])
        defaults.removeObject(forKey: "clip.ignoredApps")
        XCTAssertEqual(s.ignoredApps, ClipboardSettings.defaultIgnoredApps)

        s.passwordManagerExtensions = [PasswordManagerExtension(extensionID: "abc", displayName: "X")]
        XCTAssertEqual(s.passwordManagerExtensionIDs, ["abc"])
        s.resetPasswordManagerExtensions()
        XCTAssertEqual(s.passwordManagerExtensions, ClipboardSettings.defaultPasswordManagerExtensions)
    }

    func testCachedDateFormatterReusesAndRebuildsForANewCalendar() {
        let cache = CachedDateFormatter { $0.dateFormat = "MMM yyyy" }
        var gregorian = Calendar(identifier: .gregorian)
        let first = cache.formatter(calendar: gregorian)
        XCTAssertTrue(first === cache.formatter(calendar: gregorian))
        gregorian.firstWeekday = gregorian.firstWeekday == 1 ? 2 : 1
        let rebuilt = cache.formatter(calendar: gregorian)
        XCTAssertFalse(first === rebuilt)
        XCTAssertEqual(rebuilt.calendar, gregorian)
        XCTAssertEqual(rebuilt.dateFormat, "MMM yyyy")
    }

    func testRetentionSeconds() {
        XCTAssertNil(RetentionPeriod.forever.seconds)
        XCTAssertEqual(RetentionPeriod.day.seconds, 24 * 3600)
    }
}
