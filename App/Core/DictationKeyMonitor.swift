import AppKit
import Combine

/// Turns presses and releases of the dictation trigger into start/stop/cancel
/// commands for the selected activation mode. Pure (no clocks, no AppKit), so
/// the hold/tap/toggle rules are covered by tests.
struct DictationPressMachine: Equatable {
    enum Command: Equatable { case start, stop, cancel }

    enum State: Equatable {
        case idle
        /// Key down, recording since `since`.
        case holding(since: TimeInterval)
        /// Key up, still recording (a tap in hold-or-tap, or toggle mode).
        case latched
        /// Key down; this press stopped the recording. Waiting for release.
        case stopping
        /// Key down; the press was cancelled (another key joined it).
        case suppressed
    }

    var activation: DictationActivation
    var threshold: TimeInterval = DictationSettings.holdThreshold
    private(set) var state: State = .idle

    init(activation: DictationActivation, threshold: TimeInterval = DictationSettings.holdThreshold) {
        self.activation = activation
        self.threshold = threshold
    }

    mutating func press(at time: TimeInterval) -> Command? {
        switch state {
        case .idle:
            state = .holding(since: time)
            return .start
        case .latched:
            state = .stopping
            return .stop
        case .holding, .stopping, .suppressed:
            return nil   // key repeat
        }
    }

    mutating func release(at time: TimeInterval) -> Command? {
        switch state {
        case .holding(let since):
            switch activation {
            case .pushToTalk:
                state = .idle
                return .stop
            case .toggle:
                state = .latched
                return nil
            case .holdOrToggle:
                if time - since >= threshold {
                    state = .idle
                    return .stop
                }
                state = .latched
                return nil
            }
        case .stopping, .suppressed:
            state = .idle
            return nil
        case .idle, .latched:
            return nil
        }
    }

    /// Another key went down while the trigger was held — fn+arrow, fn+F5,
    /// ⌥+letter. That press was a shortcut, not dictation.
    mutating func interrupt() -> Command? {
        guard case .holding = state else { return nil }
        state = .suppressed
        return .cancel
    }

    /// Recording was started without the key (the menu): the next press stops it.
    mutating func recordingStartedElsewhere() {
        if state == .idle { state = .latched }
    }

    /// The recording ended some other way (Esc, the menu, the time limit).
    mutating func recordingEnded() {
        switch state {
        case .holding: state = .suppressed
        case .latched: state = .idle
        default: break
        }
    }
}

/// Watches a modifier key pressed on its own — fn/🌐 or right ⌥ — which a
/// Carbon hotkey can't express. Listen-only: the key still does whatever
/// macOS does with it, which is why the pane points at the 🌐 key setting.
/// Global key monitors need the Accessibility grant the app already holds.
@MainActor
final class DictationKeyMonitor {
    static let shared = DictationKeyMonitor()

    enum Event { case press, release, interrupt }

    /// fn / 🌐 is virtual key 63 (`kVK_Function`); right ⌥ is 61 (`kVK_RightOption`).
    nonisolated static func keyCode(for trigger: DictationTrigger) -> UInt16? {
        switch trigger {
        case .fn: return 63
        case .rightOption: return 61
        case .combo: return nil
        }
    }

    var onEvent: ((Event) -> Void)?

    private var monitors: [Any] = []
    private var watchedKey: UInt16?
    private var isDown = false
    private var cancellables: Set<AnyCancellable> = []

    func start() {
        let settings = DictationSettings.shared
        settings.$isEnabled.combineLatest(settings.$trigger)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reinstall() }
            .store(in: &cancellables)
    }

    private func reinstall() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        isDown = false
        let settings = DictationSettings.shared
        watchedKey = settings.isEnabled ? Self.keyCode(for: settings.trigger) : nil
        guard watchedKey != nil else { return }

        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
        Log.dictation.info("watching key \(self.watchedKey ?? 0) for dictation")
    }

    private func handle(_ event: NSEvent) {
        guard let watchedKey else { return }
        switch event.type {
        case .keyDown:
            if isDown { onEvent?(.interrupt) }
        case .flagsChanged:
            if event.keyCode == watchedKey {
                let flag: NSEvent.ModifierFlags = watchedKey == 63 ? .function : .option
                let down = event.modifierFlags.contains(flag)
                guard down != isDown else { return }
                isDown = down
                onEvent?(down ? .press : .release)
            } else if isDown {
                onEvent?(.interrupt)   // another modifier joined in
            }
        default:
            break
        }
    }
}
