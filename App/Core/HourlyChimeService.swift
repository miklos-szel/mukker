import AppKit
import Combine
import CoreAudio

/// Beeps at the top of every hour. The only thing in the app that plays a
/// sound of its own, and the only one that talks to CoreAudio.
///
/// Two details are load-bearing:
///
/// - The schedule is a one-shot timer armed on an **absolute** date, re-armed
///   after every fire, plus the system's clock-changed and wake notifications —
///   the same trap `KeepAwakeService` and the menu bar's day rollover document:
///   run-loop timers do not advance while the Mac is asleep, so the wall clock
///   is the authority. Never a repeating one-hour timer, which drifts away from
///   the hour with every sleep.
/// - The sound plays on the **current default output device**, looked up through
///   CoreAudio and handed to `NSSound.playbackDeviceIdentifier`. Left alone,
///   `NSSound` follows System Settings → Sound → "Play sound effects through",
///   which is frequently a different device than the one the user is listening
///   to.
@MainActor
final class HourlyChimeService: ObservableObject {
    static let shared = HourlyChimeService()

    private let settings: CalendarSettings

    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// The sound outlives the call that started it: `NSSound.play()` returns
    /// immediately, and a local would be released mid-beep.
    private var playing: NSSound?

    init(settings: CalendarSettings = .shared) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    /// Arms the schedule and keeps it armed. Called once from `AppDelegate`.
    func start() {
        // Only the on/off switch changes whether a timer exists at all; the
        // hours and the sound are read when it fires.
        settings.$hourlyChimeEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                Task { @MainActor in
                    enabled == true ? self?.scheduleNext() : self?.cancel()
                }
            }
            .store(in: &cancellables)

        // Timers stood still while asleep, and a clock change moves the hour
        // out from under an already-armed one — re-arm against the wall clock.
        Publishers.MergeMany(
            NotificationCenter.default.publisher(for: .NSSystemClockDidChange).map { _ in () },
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didWakeNotification).map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            Task { @MainActor in
                guard let self, self.settings.hourlyChimeEnabled else { return }
                self.scheduleNext()
            }
        }
        .store(in: &cancellables)

        if settings.hourlyChimeEnabled { scheduleNext() }
    }

    // MARK: - Schedule

    /// The next chime after `date`: the top of the coming hour, a second in.
    /// The offset is there for the same reason the day-rollover timer sits at
    /// second 2 — a timer aimed exactly at `:00:00` can fire a hair early and
    /// land in the previous hour, which would beep at the wrong hour and then
    /// re-arm for the same instant. Pure, so the arithmetic is testable.
    nonisolated static func nextChime(after date: Date,
                                      calendar: Calendar = .current,
                                      interval: ChimeInterval = .hourly) -> Date? {
        calendar.nextDate(after: date,
                          matching: interval.matchingComponents,
                          matchingPolicy: .nextTime)
    }

    /// Hourly in a shipping build. The debug case exists because the schedule is
    /// otherwise only exercisable by waiting an hour — see `MUKKER_CHIME_EVERY_MINUTE`.
    enum ChimeInterval {
        case hourly
        case everyMinute

        var matchingComponents: DateComponents {
            switch self {
            case .hourly: return DateComponents(minute: 0, second: 1)
            case .everyMinute: return DateComponents(second: 1)
            }
        }
    }

    private var chimeInterval: ChimeInterval {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MUKKER_CHIME_EVERY_MINUTE"] == "1" {
            return .everyMinute
        }
        #endif
        return .hourly
    }

    private func scheduleNext() {
        timer?.invalidate()
        guard let fireDate = Self.nextChime(after: Date(), interval: chimeInterval) else {
            Log.calendar.error("hourly chime: could not compute the next chime date")
            return
        }

        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in self?.fire() }
        }
        // `.common` so it still fires while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func cancel() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-arm first: an hour outside the active range is a silent no-op, not a
    /// stopped schedule.
    private func fire() {
        scheduleNext()
        let now = Date()
        guard settings.shouldChime(at: now) else { return }
        Log.calendar.info("hourly chime")
        play(named: settings.hourlyChimeSound)
    }

    // MARK: - Playback

    /// Plays the configured sound regardless of the hour or the on/off switch —
    /// what the settings pane's Test button calls.
    func chimeNow() {
        play(named: settings.hourlyChimeSound)
    }

    private func play(named name: String) {
        guard let sound = NSSound(named: name) ?? NSSound(named: Self.fallbackSounds[0]) else {
            Log.calendar.error("hourly chime: no sound named \(name, privacy: .public)")
            NSSound.beep()
            return
        }
        sound.playbackDeviceIdentifier = Self.defaultOutputDeviceUID()
        playing = sound
        sound.play()
    }

    /// UID of the system's current default output device, or nil if CoreAudio
    /// won't say — in which case `NSSound` falls back to the sound-effects
    /// device, which is still audible, just possibly elsewhere.
    private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }

        var uid: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil,
                                         &uidSize, &uid) == noErr else { return nil }
        return uid as String?
    }

    // MARK: - Sound catalogue

    /// Every system sound `NSSound(named:)` resolves, for the settings picker.
    /// Read off disk rather than hardcoded so a macOS release adding or dropping
    /// one needs no code change; the fallback covers a sandbox or a future
    /// layout in which the directories can't be listed.
    nonisolated static var availableSounds: [String] {
        let directories = ["/System/Library/Sounds",
                           NSHomeDirectory() + "/Library/Sounds"]
        var names: Set<String> = []
        for directory in directories {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for file in contents {
                let name = (file as NSString).deletingPathExtension
                if !name.isEmpty, NSSound(named: name) != nil { names.insert(name) }
            }
        }
        return names.isEmpty ? fallbackSounds : names.sorted()
    }

    private nonisolated static let fallbackSounds = ["Submarine", "Glass", "Ping", "Purr", "Tink"]
}
