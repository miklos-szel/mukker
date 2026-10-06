import Combine
import Foundation

/// A span the Network submenu can total traffic over.
enum BandwidthPeriod: String, CaseIterable, Identifiable {
    case today
    case thisWeek
    case thisMonth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .thisWeek: return "This Week"
        case .thisMonth: return "This Month"
        }
    }
}

/// Preferences for the bandwidth monitor, backed by `UserDefaults`; published
/// properties persist on change (the same shape as `WindowTilingSettings`).
@MainActor
final class BandwidthSettings: ObservableObject {
    static let shared = BandwidthSettings()

    private let defaults: UserDefaults

    /// Master switch. Off stops the sampling timer outright, drops the speed
    /// from the menu bar and the Network submenu from the menu. On by default.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: K.enabled) }
    }

    /// Show the live ↓/↑ rate beside the date. On by default — it is the point
    /// of the feature; the per-interface totals are the secondary half.
    @Published var showsInMenuBar: Bool {
        didSet { defaults.set(showsInMenuBar, forKey: K.showsInMenuBar) }
    }

    /// The periods the Network submenu lists, in `BandwidthPeriod` order.
    /// Today only out of the box.
    @Published var shownPeriods: Set<BandwidthPeriod> {
        didSet { defaults.set(shownPeriods.map(\.rawValue).sorted(), forKey: K.periods) }
    }

    /// Seconds between samples — how often the menu bar figure changes, and
    /// the window the rate is averaged over. 5 s by default: steady enough to
    /// read, without the bar flickering every second.
    @Published var refreshInterval: Int {
        didSet { defaults.set(refreshInterval, forKey: K.refreshInterval) }
    }

    static let refreshIntervals = [1, 2, 5, 10, 30]
    static let defaultRefreshInterval = 5

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A plain `defaults.bool(forKey:)` cannot express default-on.
        isEnabled = defaults.object(forKey: K.enabled) as? Bool ?? true
        showsInMenuBar = defaults.object(forKey: K.showsInMenuBar) as? Bool ?? true
        shownPeriods = defaults.stringArray(forKey: K.periods)
            .map { Set($0.compactMap(BandwidthPeriod.init(rawValue:))) } ?? [.today]
        let interval = defaults.object(forKey: K.refreshInterval) as? Int ?? Self.defaultRefreshInterval
        refreshInterval = min(max(interval, 1), 60)
    }

    func shows(_ period: BandwidthPeriod) -> Bool { shownPeriods.contains(period) }

    func setShows(_ period: BandwidthPeriod, _ shown: Bool) {
        if shown { shownPeriods.insert(period) } else { shownPeriods.remove(period) }
    }

    private enum K {
        static let enabled = "bandwidth.enabled"
        static let showsInMenuBar = "bandwidth.showsInMenuBar"
        static let periods = "bandwidth.shownPeriods"
        static let refreshInterval = "bandwidth.refreshInterval"
    }
}
