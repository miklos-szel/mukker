import AppKit
import Combine
import Foundation

/// Samples the hardware interfaces every `BandwidthSettings.refreshInterval`
/// seconds (5 by default), publishes the combined rate
/// for the menu bar and credits every byte to `BandwidthUsageStore`'s daily
/// totals.
///
/// - The timer runs on `.common`, so the menu bar figure and the Network
///   submenu keep moving while a menu is open.
/// - Rates are measured over `systemUptime`, which stops while the Mac sleeps.
///   Bytes moved during sleep (Power Nap) would then land in a one-second
///   window and show as an absurd spike, so a wake re-baselines the *rate* —
///   the bytes themselves are still credited to the totals.
/// - Only `rate` is published, and it changes once per sample: it is exactly
///   what the menu bar has to repaint, nothing more. The rate is the average
///   over the whole interval, not the last second of it.
@MainActor
final class BandwidthService: ObservableObject {
    static let shared = BandwidthService()

    /// Bits per second across every hardware interface.
    struct Rate: Equatable {
        var down: Double
        var up: Double
        static let zero = Rate(down: 0, up: 0)
    }

    @Published private(set) var rate = Rate.zero

    let store: BandwidthUsageStore
    private let settings: BandwidthSettings

    /// BSD name → display name, refreshed periodically so a dock or adapter
    /// plugged in later starts being counted without a relaunch.
    private(set) var interfaceNames: [String: String] = [:]
    private var previous: [String: InterfaceCounters] = [:]
    private var lastSampleUptime: TimeInterval?

    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// In seconds rather than ticks, so they hold at any refresh interval.
    private static let interfaceRefreshSeconds: TimeInterval = 15
    private static let flushSeconds: TimeInterval = 60
    private var lastInterfaceRefresh: TimeInterval = 0
    private var lastFlush: TimeInterval = 0

    init(settings: BandwidthSettings, store: BandwidthUsageStore) {
        self.settings = settings
        self.store = store
    }

    private convenience init() {
        self.init(settings: .shared, store: BandwidthUsageStore())
    }

    func start() {
        settings.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in enabled ? self?.resume() : self?.pause() }
            .store(in: &cancellables)

        // A new interval re-arms the timer; the counters' baseline is kept.
        settings.$refreshInterval
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] interval in self?.scheduleTimer(every: interval) }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.lastSampleUptime = nil }
            .store(in: &cancellables)
    }

    func flush() { store.flush() }

    func resetStatistics() { store.reset() }

    /// Re-reads the interface list now — the menu calls this on open so a
    /// just-plugged adapter shows up immediately.
    func refreshInterfaces() {
        interfaceNames = NetworkCounters.hardwareInterfaces()
        lastInterfaceRefresh = ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Sampling

    private func resume() {
        guard timer == nil else { return }
        refreshInterfaces()
        // First reading is a baseline only: the counters hold everything since
        // boot, none of which belongs to today's totals.
        previous = NetworkCounters.sample(including: Set(interfaceNames.keys))
        lastSampleUptime = ProcessInfo.processInfo.systemUptime
        lastFlush = lastSampleUptime ?? 0
        scheduleTimer(every: settings.refreshInterval)
        Log.network.info("bandwidth sampling started (\(self.interfaceNames.count) interfaces)")
    }

    private func scheduleTimer(every seconds: Int) {
        guard timer != nil || settings.isEnabled else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(seconds), repeats: true) { _ in
            MainActor.assumeIsolated { BandwidthService.shared.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
        previous = [:]
        lastSampleUptime = nil
        store.flush()
        rate = .zero
        Log.network.info("bandwidth sampling stopped")
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastInterfaceRefresh >= Self.interfaceRefreshSeconds { refreshInterfaces() }
        let current = NetworkCounters.sample(including: Set(interfaceNames.keys))
        var deltas: [String: InterfaceCounters] = [:]
        for (name, counters) in current {
            // An interface seen for the first time only sets its baseline.
            guard let before = previous[name] else { continue }
            deltas[name] = InterfaceCounters(
                received: NetworkCounters.delta(previous: before.received, current: counters.received),
                sent: NetworkCounters.delta(previous: before.sent, current: counters.sent))
        }
        previous = current
        store.add(deltas, at: Date())

        if let last = lastSampleUptime, now - last > 0.2 {
            let elapsed = now - last
            let sum = deltas.values.reduce(InterfaceCounters.zero, +)
            rate = Rate(down: Double(sum.received) * 8 / elapsed, up: Double(sum.sent) * 8 / elapsed)
        } else {
            // Just woke (or first tick): no trustworthy interval to divide by.
            rate = .zero
        }
        lastSampleUptime = now

        if now - lastFlush >= Self.flushSeconds {
            store.flush()
            lastFlush = now
        }
    }
}
