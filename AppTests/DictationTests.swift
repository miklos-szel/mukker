import XCTest
import Combine
import HotKey
@testable import AppCore

/// The pure halves of Dictation: the hold/tap/toggle rules, how the language
/// hint is chosen, the model catalog, checksum verification, settings and the
/// final text. The microphone, the key monitor and the model itself are
/// verified by hand (`MUKKER_DICTATE_FILE` exercises the engine).
@MainActor
final class DictationTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AppTests-\(UUID().uuidString)")!
    }

    // MARK: - Press machine

    func testPushToTalkRecordsWhileHeld() {
        var machine = DictationPressMachine(activation: .pushToTalk)
        XCTAssertEqual(machine.press(at: 0), .start)
        XCTAssertNil(machine.press(at: 0.1), "key repeat is ignored")
        XCTAssertEqual(machine.release(at: 0.05), .stop, "even a short press stops on release")
        XCTAssertEqual(machine.state, .idle)
    }

    func testToggleStartsAndStopsOnPresses() {
        var machine = DictationPressMachine(activation: .toggle)
        XCTAssertEqual(machine.press(at: 0), .start)
        XCTAssertNil(machine.release(at: 2), "a long hold still latches in toggle mode")
        XCTAssertEqual(machine.state, .latched)
        XCTAssertEqual(machine.press(at: 5), .stop)
        XCTAssertNil(machine.release(at: 5.1))
        XCTAssertEqual(machine.state, .idle)
    }

    func testHoldOrToggleHoldIsPushToTalk() {
        var machine = DictationPressMachine(activation: .holdOrToggle, threshold: 0.3)
        XCTAssertEqual(machine.press(at: 10), .start)
        XCTAssertEqual(machine.release(at: 10.3), .stop, "exactly the threshold counts as a hold")
    }

    func testHoldOrToggleTapLatches() {
        var machine = DictationPressMachine(activation: .holdOrToggle, threshold: 0.3)
        XCTAssertEqual(machine.press(at: 10), .start)
        XCTAssertNil(machine.release(at: 10.29))
        XCTAssertEqual(machine.state, .latched)
        XCTAssertEqual(machine.press(at: 14), .stop)
        XCTAssertNil(machine.release(at: 14.1), "the stopping press's release does nothing")
        XCTAssertEqual(machine.press(at: 20), .start, "and the next press starts again")
    }

    func testAnotherKeyCancelsAHeldPress() {
        var machine = DictationPressMachine(activation: .holdOrToggle)
        XCTAssertEqual(machine.press(at: 0), .start)
        XCTAssertEqual(machine.interrupt(), .cancel)
        XCTAssertNil(machine.interrupt(), "only once")
        XCTAssertNil(machine.release(at: 1), "the release of a cancelled press is ignored")
        XCTAssertEqual(machine.state, .idle)
    }

    func testTypingWhileLatchedDoesNotCancel() {
        var machine = DictationPressMachine(activation: .toggle)
        _ = machine.press(at: 0)
        _ = machine.release(at: 0.1)
        XCTAssertNil(machine.interrupt())
        XCTAssertEqual(machine.state, .latched)
    }

    func testRecordingEndedElsewhere() {
        var held = DictationPressMachine(activation: .pushToTalk)
        _ = held.press(at: 0)
        held.recordingEnded()   // e.g. Esc while the key is still down
        XCTAssertNil(held.release(at: 1), "no stop for a recording that already ended")
        XCTAssertEqual(held.state, .idle)

        var latched = DictationPressMachine(activation: .toggle)
        _ = latched.press(at: 0)
        _ = latched.release(at: 0.1)
        latched.recordingEnded()
        XCTAssertEqual(latched.press(at: 3), .start, "the next press starts a new recording")
    }

    func testMenuStartedRecordingStopsOnNextPress() {
        var machine = DictationPressMachine(activation: .pushToTalk)
        machine.recordingStartedElsewhere()
        XCTAssertEqual(machine.press(at: 0), .stop)
    }

    // MARK: - Language plan

    private var parakeet: DictationModel { DictationCatalog.model(id: "parakeet-ultra") }
    private var whisper: DictationModel { DictationCatalog.model(id: "whisper-large-v3-turbo") }

    func testParakeetAlwaysDecidesItself() {
        XCTAssertEqual(DictationLanguagePlan.plan(model: parakeet, selected: .german, preferred: [.english]),
                       .modelDecides)
    }

    func testFixedLanguageWins() {
        XCTAssertEqual(DictationLanguagePlan.plan(model: whisper, selected: .hungarian, preferred: [.english]),
                       .fixed(.hungarian))
    }

    func testAutomaticDetectsAmongPreferred() {
        XCTAssertEqual(DictationLanguagePlan.plan(model: whisper, selected: nil, preferred: [.hungarian, .english]),
                       .detect(among: [.english, .hungarian]), "in catalog order")
    }

    func testAutomaticWithOnePreferredIsFixed() {
        XCTAssertEqual(DictationLanguagePlan.plan(model: whisper, selected: nil, preferred: [.german]),
                       .fixed(.german))
    }

    func testAutomaticWithNothingPreferredUsesAllThree() {
        XCTAssertEqual(DictationLanguagePlan.plan(model: whisper, selected: nil, preferred: []),
                       .detect(among: [.english, .german, .hungarian]))
    }

    // MARK: - Catalog

    func testDefaultModelIsWhisperTurbo() {
        XCTAssertEqual(DictationCatalog.defaultModelID, "whisper-large-v3-turbo")
        XCTAssertEqual(DictationCatalog.model(id: "no-such-model").id, "whisper-large-v3-turbo")
        XCTAssertTrue(DictationCatalog.models.contains { $0.id == "parakeet-ultra" })
    }

    func testCatalogEntriesArePinned() {
        let ids = DictationCatalog.models.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for file in DictationCatalog.models.map(\.file) + [DictationCatalog.languageDetector] {
            XCTAssertEqual(file.revision.count, 40, "\(file.fileName) pinned to a full commit")
            XCTAssertEqual(file.sha256.count, 64)
            XCTAssertGreaterThan(file.byteSize, 0)
            XCTAssertEqual(file.downloadURL.absoluteString,
                           "https://huggingface.co/\(file.repo)/resolve/\(file.revision)/\(file.fileName)")
        }
    }

    func testOnlyHintableModelsNeedTheDetector() {
        XCTAssertEqual(DictationCatalog.files(for: whisper), [whisper.file, DictationCatalog.languageDetector])
        XCTAssertEqual(DictationCatalog.files(for: parakeet), [parakeet.file])
    }

    // MARK: - Checksum

    func testSHA256OfFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(DictationModelStore.sha256(of: url),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNil(DictationModelStore.sha256(of: url.appendingPathExtension("missing")))
    }

    // MARK: - Settings

    func testSettingsDefaults() {
        let settings = DictationSettings(defaults: makeDefaults())
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.trigger, .fn)
        XCTAssertEqual(settings.activation, .holdOrToggle)
        XCTAssertEqual(settings.modelID, "whisper-large-v3-turbo")
        XCTAssertNil(settings.language)
        XCTAssertEqual(settings.microphoneUID, "")
        XCTAssertTrue(settings.soundsEnabled)
        XCTAssertTrue(settings.overlayEnabled)
        XCTAssertEqual(settings.unloadDelay, .fiveMinutes)
    }

    func testSettingsPersist() {
        let defaults = makeDefaults()
        let first = DictationSettings(defaults: defaults)
        first.trigger = .rightOption
        first.activation = .toggle
        first.language = .german
        first.preferredLanguages = [.german, .hungarian]
        first.modelID = "parakeet-ultra"
        let second = DictationSettings(defaults: defaults)
        XCTAssertEqual(second.trigger, .rightOption)
        XCTAssertEqual(second.activation, .toggle)
        XCTAssertEqual(second.language, .german)
        XCTAssertEqual(second.preferredLanguages, [.german, .hungarian])
        XCTAssertEqual(second.modelID, "parakeet-ultra")

        first.language = nil
        XCTAssertNil(DictationSettings(defaults: defaults).language, "Automatic round-trips")
    }

    func testUnknownStoredModelFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set("retired-model", forKey: "dictationModel")
        XCTAssertEqual(DictationSettings(defaults: defaults).modelID, DictationCatalog.defaultModelID)
    }

    func testDefaultPreferredLanguagesFollowSystem() {
        XCTAssertEqual(DictationSettings.defaultPreferredLanguages(systemLanguages: ["hu-HU", "en-US"]),
                       [.english, .hungarian])
        XCTAssertEqual(DictationSettings.defaultPreferredLanguages(systemLanguages: ["fr-FR"]), [.english])
        XCTAssertEqual(DictationSettings.defaultPreferredLanguages(systemLanguages: ["de", "hu"]),
                       [.english, .german, .hungarian])
    }

    func testDictationComboDefaultAndReset() {
        let shortcuts = ShortcutSettings(defaults: makeDefaults())
        XCTAssertEqual(shortcuts.dictationCombo, KeyCombo(key: .space, modifiers: [.option]))
        shortcuts.dictationCombo = KeyCombo(key: .d, modifiers: [.command, .option])
        shortcuts.resetToDefaults()
        XCTAssertEqual(shortcuts.dictationCombo, ShortcutSettings.defaultDictationCombo)
    }

    func testDictationComboChangeIsPublishedOnce() {
        let shortcuts = ShortcutSettings(defaults: makeDefaults())
        var count = 0
        let cancellable = shortcuts.comboChanges.sink { count += 1 }
        XCTAssertEqual(count, 0, "no replay at subscribe")
        shortcuts.dictationCombo = KeyCombo(key: .d, modifiers: [.command, .option])
        XCTAssertEqual(count, 1)
        cancellable.cancel()
    }

    // MARK: - Text and trigger keys

    func testFinalText() {
        XCTAssertEqual(DictationService.finalText("  Hello there.\n", appendTrailingSpace: false), "Hello there.")
        XCTAssertEqual(DictationService.finalText("Hello", appendTrailingSpace: true), "Hello ")
        XCTAssertEqual(DictationService.finalText(" \n ", appendTrailingSpace: true), "")
    }

    func testTriggerKeyCodes() {
        XCTAssertEqual(DictationKeyMonitor.keyCode(for: .fn), 63)
        XCTAssertEqual(DictationKeyMonitor.keyCode(for: .rightOption), 61)
        XCTAssertNil(DictationKeyMonitor.keyCode(for: .combo))
    }

    func testLevelMapping() {
        XCTAssertEqual(DictationRecorder.rmsLevel([]), 0)
        XCTAssertEqual(DictationRecorder.rmsLevel([0, 0, 0]), 0)
        XCTAssertEqual(DictationRecorder.rmsLevel([1, -1, 1, -1]), 1, accuracy: 0.001)
    }
}
