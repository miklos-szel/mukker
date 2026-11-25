import AppKit
import Combine

/// Dictation's coordinator: the trigger's presses become recording, the
/// recording becomes text, and the text is pasted into the app that was in
/// front — through `Paster.pasteText`, so it also stays on the clipboard and
/// lands in history like any other copy.
@MainActor
final class DictationService: ObservableObject {
    static let shared = DictationService()

    enum State: Equatable {
        case idle
        case recording
        case transcribing
        /// A short note for the overlay (no model, nothing heard, an error).
        case notice(String)
    }

    @Published private(set) var state: State = .idle
    /// Microphone level, 0…1, while recording.
    @Published private(set) var level: Float = 0

    var isRecording: Bool { state == .recording }

    /// Opens Settings on the Dictation tab (wired by `AppDelegate`).
    var onRequestSettings: () -> Void = {}

    /// Anything shorter is a stray tap, not speech.
    nonisolated static let minimumDuration: TimeInterval = 0.3

    private let settings = DictationSettings.shared
    private let recorder = DictationRecorder()
    private var machine = DictationPressMachine(activation: DictationSettings.shared.activation)
    private var escapeMonitors: [Any] = []
    private var noticeTimer: Timer?
    private var playing: NSSound?
    /// The language of the per-language shortcut that started this recording, if any.
    private var forcedLanguage: DictationLanguage?
    private var pendingLanguage: DictationLanguage?
    private var generation = 0
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        recorder.onLevel = { [weak self] level in self?.level = level }
        recorder.onLimitReached = { [weak self] in
            guard let self, self.isRecording else { return }
            Log.dictation.info("recording reached the time limit")
            self.machine.recordingEnded()
            self.finishRecording()
        }
    }

    func start() {
        DictationKeyMonitor.shared.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .press: self.press()
            case .release: self.release()
            case .interrupt: self.interrupt()
            }
        }
        DictationKeyMonitor.shared.start()
        settings.$activation
            .sink { [weak self] activation in self?.machine = DictationPressMachine(activation: activation) }
            .store(in: &cancellables)
        // A different model frees the old one's memory now rather than at the idle timeout.
        settings.$modelID.dropFirst().removeDuplicates()
            .sink { _ in TranscriptionEngine.shared.unload() }
            .store(in: &cancellables)
    }

    // MARK: - Trigger

    func press(language: DictationLanguage? = nil) {
        pendingLanguage = language
        defer { pendingLanguage = nil }
        apply(machine.press(at: ProcessInfo.processInfo.systemUptime))
    }

    func release() {
        apply(machine.release(at: ProcessInfo.processInfo.systemUptime))
    }

    private func interrupt() {
        apply(machine.interrupt())
    }

    /// The menu item: start when idle, stop when recording.
    func toggleFromMenu() {
        if isRecording {
            machine.recordingEnded()
            finishRecording()
        } else if beginRecording() {
            machine.recordingStartedElsewhere()
        }
    }

    private func apply(_ command: DictationPressMachine.Command?) {
        switch command {
        case .start:
            if !beginRecording() { machine.recordingEnded() }
        case .stop:
            finishRecording()
        case .cancel:
            cancelRecording(reason: "another key joined the trigger")
        case nil:
            break
        }
    }

    // MARK: - Recording

    /// Returns whether recording actually started.
    @discardableResult
    private func beginRecording() -> Bool {
        guard settings.isEnabled, state != .recording, state != .transcribing else { return false }
        let model = settings.model
        guard DictationModelStore.shared.isInstalled(model) else {
            showNotice("Download \(model.name) in Settings → Dictation first.")
            onRequestSettings()
            return false
        }
        guard PermissionsService.shared.hasMicrophonePermission else {
            // The prompt (or the "denied" alert) takes over; the next press records.
            Task { _ = await PermissionsService.shared.ensureMicrophone() }
            return false
        }

        ActiveAppTracker.shared.captureFrontmost()
        TranscriptionEngine.shared.prewarm(model)
        do {
            try recorder.start(deviceUID: settings.microphoneUID)
        } catch {
            Log.dictation.error("recording failed to start: \(error.localizedDescription, privacy: .public)")
            showNotice(error.localizedDescription)
            return false
        }
        noticeTimer?.invalidate()
        level = 0
        state = .recording
        forcedLanguage = pendingLanguage
        installEscapeMonitors()
        playSound(.start)
        Log.dictation.info("recording started")
        return true
    }

    private func finishRecording() {
        guard isRecording else { return }
        removeEscapeMonitors()
        let samples = recorder.stop()
        let forced = forcedLanguage
        forcedLanguage = nil
        playSound(.stop)
        let duration = Double(samples.count) / DictationRecorder.sampleRate
        guard duration >= Self.minimumDuration else {
            Log.dictation.info("recording too short (\(Int(duration * 1000)) ms); dropped")
            state = .idle
            return
        }

        state = .transcribing
        generation += 1
        let token = generation
        let model = settings.model
        let plan = DictationLanguagePlan.plan(model: model, selected: settings.language,
                                              preferred: settings.preferredLanguages, forced: forced)
        TranscriptionEngine.shared.transcribe(samples, model: model, plan: plan) { [weak self] outcome in
            guard let self, token == self.generation else { return }
            switch outcome {
            case .success(let result):
                self.deliver(result.text)
            case .failure(let error):
                Log.dictation.error("transcription failed: \(String(describing: error), privacy: .public)")
                self.showNotice("Couldn't transcribe: \(error.localizedDescription)")
            }
        }
    }

    private func cancelRecording(reason: String) {
        guard isRecording else { return }
        removeEscapeMonitors()
        recorder.cancel()
        forcedLanguage = nil
        state = .idle
        Log.dictation.info("recording cancelled: \(reason, privacy: .public)")
    }

    private func deliver(_ raw: String) {
        let text = Self.finalText(raw, appendTrailingSpace: settings.appendTrailingSpace)
        guard !text.isEmpty else {
            showNotice("Nothing heard.")
            return
        }
        state = .idle
        Paster.shared.pasteText(text)
        playSound(.paste)
    }

    /// Trims what the model returns and optionally adds one trailing space, so
    /// consecutive dictations don't run together.
    nonisolated static func finalText(_ raw: String, appendTrailingSpace: Bool) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return appendTrailingSpace ? trimmed + " " : trimmed
    }

    // MARK: - Esc cancels

    private func installEscapeMonitors() {
        removeEscapeMonitors()
        let handler: (NSEvent) -> Bool = { [weak self] event in
            guard event.keyCode == 53 else { return false }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.machine.recordingEnded()
                self.cancelRecording(reason: "Esc")
            }
            return true
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = handler($0) }) {
            escapeMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0) ? nil : $0 }) {
            escapeMonitors.append(local)
        }
    }

    private func removeEscapeMonitors() {
        escapeMonitors.forEach(NSEvent.removeMonitor)
        escapeMonitors = []
    }

    // MARK: - Feedback

    private func showNotice(_ message: String) {
        state = .notice(message)
        noticeTimer?.invalidate()
        let timer = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .notice = self.state else { return }
                self.state = .idle
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        noticeTimer = timer
    }

    private enum Cue: String {
        case start = "dictation-start"
        case stop = "dictation-stop"
        case paste = "dictation-paste"

        /// The old system sound, used only if the bundled file is missing.
        var fallback: String { self == .start ? "Tink" : "Pop" }
    }

    /// Plays on the current default output device, like the hourly chime —
    /// `NSSound` would otherwise follow "Play sound effects through". Retained,
    /// since `play()` returns at once. The cues are bundled WAVs
    /// (`scripts/make-sounds.py`, shared with Windows).
    private func playSound(_ cue: Cue) {
        guard settings.soundsEnabled else { return }
        let sound: NSSound?
        if let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav") {
            sound = NSSound(contentsOf: url, byReference: true)
        } else {
            sound = NSSound(named: cue.fallback)?.copy() as? NSSound
        }
        guard let sound else { return }
        sound.volume = Float(settings.soundVolume)
        sound.playbackDeviceIdentifier = AudioDevices.defaultOutputDeviceUID()
        playing = sound
        sound.play()
    }
}
