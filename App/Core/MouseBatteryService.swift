import AppKit
import Combine

/// What the menu shows for the mouse.
struct MouseBatteryReading: Equatable {
    var modelName: String
    /// The last percentage the mouse reported, kept while it sleeps.
    var percent: Int?
    var isCharging: Bool
    /// When `percent` was read; nil if it never answered.
    var updated: Date?
    /// The device is attached but the last read got no answer (asleep or off).
    var isAsleep: Bool

    func isLow(threshold: Int) -> Bool {
        guard let percent, !isCharging else { return false }
        return percent < threshold
    }
}

/// Polls a connected wireless Razer mouse for its battery level. The only
/// caller of `RazerBattery`; reads run on a serial background queue because
/// each USB round trip waits ~60 ms for the receiver.
///
/// Polled every five minutes so the low-battery row at the top of the menu is
/// already current when the menu is built, plus on every menu open, on wake
/// and on demand from the submenu's Refresh item.
@MainActor
final class MouseBatteryService: ObservableObject {
    static let shared = MouseBatteryService()

    /// nil when no supported mouse is attached (or the feature is off).
    @Published private(set) var reading: MouseBatteryReading?

    enum Band: Equatable { case low, medium, ok }

    nonisolated static func band(for percent: Int, threshold: Int) -> Band {
        if percent < threshold { return .low }
        if percent < 50 { return .medium }
        return .ok
    }

    nonisolated static func color(for percent: Int, threshold: Int) -> NSColor {
        switch band(for: percent, threshold: threshold) {
        case .low: return .systemRed
        case .medium: return .systemOrange
        case .ok: return .systemGreen
        }
    }

    static let pollInterval: TimeInterval = 300

    private let queue = DispatchQueue(label: "\(Branding.bundleID).mouse-battery", qos: .utility)
    private var timer: Timer?
    private var isReading = false
    private var cancellables: Set<AnyCancellable> = []
    /// `MUKKER_MOUSE_BATTERY=<n>` (DEBUG) fakes a reading instead of polling.
    private var debugOverride: Int?

    func start() {
#if DEBUG
        if let value = ProcessInfo.processInfo.environment["MUKKER_MOUSE_BATTERY"], let percent = Int(value) {
            debugOverride = percent
        }
#endif
        applyEnabled()
        // `@Published` replays on subscribe (hence `dropFirst`) and emits before
        // it stores, so act after delivery.
        MouseBatterySettings.shared.$isEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyEnabled() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func applyEnabled() {
        timer?.invalidate()
        timer = nil
        guard MouseBatterySettings.shared.isEnabled else {
            Log.mouse.info("Mouse battery off")
            reading = nil
            return
        }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { MouseBatteryService.shared.refresh() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// Starts a read unless one is in flight. The result is delivered on the
    /// main run loop in `.common` mode, so an open menu sees it.
    func refresh() {
        guard MouseBatterySettings.shared.isEnabled, !isReading else { return }
        if let debugOverride {
            reading = MouseBatteryReading(modelName: "Razer Viper Ultimate (debug)", percent: debugOverride,
                                          isCharging: false, updated: Date(), isAsleep: false)
            return
        }
        isReading = true
        queue.async {
            let status = RazerBattery.readStatus()
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { MouseBatteryService.shared.apply(status) }
            }
        }
    }

    private func apply(_ status: RazerBattery.Status?) {
        isReading = false
        guard MouseBatterySettings.shared.isEnabled else { reading = nil; return }
        guard let status else {
            if reading != nil { Log.mouse.info("No supported Razer mouse attached") }
            reading = nil
            return
        }
        var next = reading?.modelName == status.model.name
            ? reading!
            : MouseBatteryReading(modelName: status.model.name, percent: nil, isCharging: false,
                                  updated: nil, isAsleep: false)
        if let percent = status.percent {
            next.percent = percent
            next.isCharging = status.isCharging
            next.updated = Date()
            next.isAsleep = false
        } else {
            next.isAsleep = true
        }
        if next != reading { reading = next }
    }
}
