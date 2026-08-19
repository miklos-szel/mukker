import AppKit
import Combine
import IOKit.pwr_mgt

/// Owns the IOKit power assertion that keeps the Mac awake, plus the countdown
/// that releases it again. The only thing in the app that talks to IOKit power
/// management — everything else toggles this service.
///
/// Two details are load-bearing:
///
/// - The assertion is created with a **short timeout and re-created on a timer**
///   (`assertionTimeout` > `refreshInterval`, so consecutive assertions overlap
///   and the machine is never briefly sleepable). A long-lived assertion would
///   survive a crash or a `kill -9` and pin the Mac awake with nothing left to
///   release it; a self-expiring one drains within `assertionTimeout`.
/// - The deadline is an absolute `Date`, not a countdown. Run-loop timers do not
///   advance while the Mac is asleep, so on wake we compare against the wall
///   clock instead of trusting the timer.
@MainActor
final class KeepAwakeService: ObservableObject {
    static let shared = KeepAwakeService()

    /// Whether an assertion is currently held. The only *stored* published
    /// property; the countdown deliberately isn't one. `AppMain` observes this
    /// service to pick the menu-bar icon and to render the menu's status line,
    /// and a value that changed every second would rebuild the whole
    /// `MenuBarExtra` body (and can close an open menu). Instead the object
    /// republishes once a minute while counting down — the same granularity
    /// `format(remaining:)` shows above a minute, so the menu is never visibly
    /// stale.
    @Published private(set) var isActive = false

    /// Seconds until the assertion is released, or nil when active indefinitely
    /// (or inactive). Derived from the deadline on read, so it is accurate
    /// without a ticking timer — callers that want a live countdown poll it
    /// (see `KeepAwakePane`), the way `PermissionsPane` polls permission status.
    var remaining: TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSinceNow) }
    }

    private let settings: KeepAwakeSettings

    private var assertionID: IOPMAssertionID?
    private var refreshTimer: Timer?
    private var expiryTimer: Timer?
    private var menuRefreshTimer: Timer?
    private var deadline: Date?
    private var isUserSessionActive = true
    private var cancellables: Set<AnyCancellable> = []

    /// Lifetime of a single assertion. It has to outlast `refreshInterval` so a
    /// refresh always overlaps the assertion it replaces.
    private static let assertionTimeout: TimeInterval = 30
    private static let refreshInterval: TimeInterval = 10

    init(settings: KeepAwakeSettings = .shared) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    /// Installs the workspace observers and honours "turn on at launch". Called
    /// once from `AppDelegate`.
    func start() {
        observeWorkspace()

        // Switching the display-sleep preference while active swaps the assertion
        // type, so re-assert immediately instead of waiting for the next refresh.
        settings.$allowDisplaySleep
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.isActive else { return }
                self.refreshAssertion()
            }
            .store(in: &cancellables)

        if settings.activateAtLaunch {
            activate()
        }
    }

    // MARK: - Public API

    /// Turns Keep Awake on for the user's configured default duration.
    func activate() {
        activate(for: settings.defaultDuration)
    }

    /// Turns Keep Awake on for `duration`, restarting the countdown if it was
    /// already on.
    func activate(for duration: KeepAwakeDuration) {
        cancelTimers()

        if let interval = duration.interval {
            deadline = Date().addingTimeInterval(interval)
            scheduleExpiry(after: interval)
            startMenuRefreshing()
        } else {
            deadline = nil
        }

        isActive = true
        startRefreshing()
        Log.keepAwake.info("activated (\(duration.label, privacy: .public))")
    }

    /// Turns Keep Awake off and releases the assertion.
    func deactivate() {
        guard isActive || assertionID != nil else { return }
        cancelTimers()
        deadline = nil
        isActive = false
        releaseAssertion()
        Log.keepAwake.info("deactivated")
    }

    func toggle() {
        if isActive { deactivate() } else { activate() }
    }

    /// One-line state for the menu and the settings pane.
    var statusText: String {
        guard isActive else { return "Off" }
        guard let remaining else { return "On — until turned off" }
        return "On — \(Self.format(remaining: remaining)) left"
    }

    /// Compact remaining-time string: `1h 58m`, `58m`, `45s`. Seconds only show
    /// in the final minute, which is what lets the menu republish once a minute
    /// without ever displaying a stale value. Pure, so it stays off the main
    /// actor and is testable without the service.
    nonisolated static func format(remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    // MARK: - Timers

    private func startRefreshing() {
        refreshAssertion()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAssertion() }
        }
        // `.common` so the assertion keeps refreshing while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// One-shot timer that ends the activation. The wall-clock deadline is the
    /// real authority — see `reconcileAfterWake`, since this timer stands still
    /// while the Mac sleeps.
    private func scheduleExpiry(after interval: TimeInterval) {
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                Log.keepAwake.info("duration elapsed")
                self?.deactivate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    /// Republishes once a minute so anything rendered from the object (the
    /// menu's status line) keeps up with the countdown without per-second churn.
    private func startMenuRefreshing() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuRefreshTimer = timer
    }

    private func cancelTimers() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        expiryTimer?.invalidate()
        expiryTimer = nil
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
    }

    // MARK: - Assertion

    /// Creates a fresh assertion and drops the previous one. New before old, so
    /// the two overlap and there is no window in which the Mac may idle-sleep.
    private func refreshAssertion() {
        guard isUserSessionActive else { return }

        let type = settings.allowDisplaySleep
            ? kIOPMAssertPreventUserIdleSystemSleep
            : kIOPMAssertPreventUserIdleDisplaySleep
        let previous = assertionID

        var created: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithDescription(
            type as CFString,
            "\(Branding.name) is keeping this Mac awake" as CFString,
            nil, nil, nil,
            Self.assertionTimeout,
            nil,
            &created
        )

        guard result == kIOReturnSuccess else {
            Log.keepAwake.error("IOPMAssertionCreateWithDescription failed: \(result)")
            return
        }

        assertionID = created
        if let previous { IOPMAssertionRelease(previous) }
    }

    private func releaseAssertion() {
        guard let assertionID else { return }
        IOPMAssertionRelease(assertionID)
        self.assertionID = nil
    }

    // MARK: - Workspace notifications

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter

        // An explicit sleep should win over an assertion the user forgot about.
        center.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.settings.deactivateOnManualSleep else { return }
                    self.deactivate()
                }
            }
            .store(in: &cancellables)

        // Timers stood still while asleep — settle up against the wall clock.
        center.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.reconcileAfterWake() }
            }
            .store(in: &cancellables)

        // Fast user switching: holding an assertion for a session nobody is
        // looking at keeps the *other* user's Mac awake too.
        center.publisher(for: NSWorkspace.sessionDidResignActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.isUserSessionActive = false
                    self?.releaseAssertion()
                }
            }
            .store(in: &cancellables)

        center.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.isUserSessionActive = true
                    if self.isActive { self.refreshAssertion() }
                }
            }
            .store(in: &cancellables)
    }

    private func reconcileAfterWake() {
        guard isActive else { return }
        if let deadline, deadline.timeIntervalSinceNow <= 0 {
            Log.keepAwake.info("duration elapsed while asleep")
            deactivate()
        } else {
            refreshAssertion()
        }
    }
}
