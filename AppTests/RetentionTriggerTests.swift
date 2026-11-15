import XCTest
@testable import AppCore

@MainActor
final class RetentionTriggerTests: XCTestCase {

    private func makeSettings() -> ClipboardSettings {
        ClipboardSettings(defaults: UserDefaults(suiteName: "AppTests-\(UUID().uuidString)")!)
    }

    func testUnrelatedSettingsLeaveTheSnapshotUnchanged() {
        let settings = makeSettings()
        let before = ClipboardRetentionService.RetentionSnapshot(settings)
        settings.popupSizePercent = 0.8
        settings.highlightSearchMatches.toggle()
        settings.maxHistoryItems = 42
        XCTAssertEqual(ClipboardRetentionService.RetentionSnapshot(settings), before)
    }

    func testRetentionAndKeepTogglesChangeTheSnapshot() {
        let settings = makeSettings()
        var last = ClipboardRetentionService.RetentionSnapshot(settings)
        let changes: [() -> Void] = [
            { settings.textRetention = .day },
            { settings.imageRetention = .week },
            { settings.fileRetention = .year },
            { settings.keepText = false },
            { settings.keepImages = false },
            { settings.keepFiles = false },
        ]
        for change in changes {
            change()
            let current = ClipboardRetentionService.RetentionSnapshot(settings)
            XCTAssertNotEqual(current, last)
            last = current
        }
    }
}
