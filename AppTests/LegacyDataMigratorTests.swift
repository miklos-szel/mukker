import XCTest
@testable import AppCore

/// The migrator is what keeps a user's history and settings alive across the
/// app's rename + bundle-ID change, so its precedence and filtering rules are
/// worth pinning down. Only the preferences half is covered here — the database
/// half copies files inside the real Application Support directory, which a test
/// has no business doing.
final class LegacyDataMigratorTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var legacyDomains: [String] = []

    override func setUp() {
        super.setUp()
        suiteName = "AppTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        for domain in legacyDomains + [suiteName] {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        super.tearDown()
    }

    private func seed(_ domain: String, _ values: [String: Any]) -> String {
        let name = "\(domain)-\(UUID().uuidString)"
        UserDefaults.standard.setPersistentDomain(values, forName: name)
        legacyDomains.append(name)
        return name
    }

    @MainActor
    func testImportsSettingsFromAPreviousIdentity() {
        let old = seed("legacy", ["clip.textRetention": "month", "canvasPadding": 71.5])

        LegacyDataMigrator.importLegacyDefaults(into: defaults, from: [old])

        XCTAssertEqual(defaults.string(forKey: "clip.textRetention"), "month")
        XCTAssertEqual(defaults.double(forKey: "canvasPadding"), 71.5)
    }

    /// Domains are listed oldest-first, so the most recent identity's value must
    /// survive — otherwise a stale pre-merge setting would clobber a current one.
    @MainActor
    func testNewerIdentityWinsOverOlder() {
        let older = seed("older", ["afterCapture": "save"])
        let newer = seed("newer", ["afterCapture": "copy"])

        LegacyDataMigrator.importLegacyDefaults(into: defaults, from: [older, newer])

        XCTAssertEqual(defaults.string(forKey: "afterCapture"), "copy")
    }

    @MainActor
    func testSkipsSystemKeysAndMigrationBookkeeping() {
        let old = seed("legacy", [
            "clip.keepImages": true,
            "migration.legacyImportVersion": 1,
            "NSWindow Frame SettingsWindow": "0 0 100 100",
            "AppleLanguages": ["en"]
        ])

        LegacyDataMigrator.importLegacyDefaults(into: defaults, from: [old])

        XCTAssertTrue(defaults.bool(forKey: "clip.keepImages"))
        // Assert against what we actually wrote into our own domain, not
        // `object(forKey:)` — that resolves through NSGlobalDomain, where keys
        // like AppleLanguages always exist whether we imported them or not.
        let written = UserDefaults.standard.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertNil(written["migration.legacyImportVersion"],
                     "migration bookkeeping must not be inherited, or the migration re-runs wrong")
        XCTAssertNil(written["NSWindow Frame SettingsWindow"])
        XCTAssertNil(written["AppleLanguages"])
    }
}
