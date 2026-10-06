import Foundation

extension InterfaceCounters {
    static let zero = InterfaceCounters(received: 0, sent: 0)
    var total: UInt64 { received &+ sent }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(received: lhs.received &+ rhs.received, sent: lhs.sent &+ rhs.sent)
    }
}

/// Daily per-interface transfer totals: `[day "yyyy-MM-dd": [bsdName: counters]]`.
///
/// Kept in memory and flushed to `UserDefaults` by `BandwidthService` once a
/// minute and on quit — never per tick. Like Keep Awake this side never touches
/// `AppDatabase`: a couple of months of daily rows for a handful of interfaces
/// is a few kilobytes.
///
/// The kernel counters reset at boot and say nothing about *when* bytes moved,
/// which is why the totals have to be accumulated here at all. The flip side:
/// traffic while the app isn't running is never counted.
@MainActor
final class BandwidthUsageStore {
    typealias Days = [String: [String: InterfaceCounters]]

    private let defaults: UserDefaults
    private(set) var days: Days
    private var isDirty = false

    /// Longest period the menu can show is a month; a margin past that keeps
    /// last month's tail around without growing forever.
    nonisolated static let retainedDays = 62

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        days = defaults.data(forKey: K.days)
            .flatMap { try? JSONDecoder().decode(Days.self, from: $0) } ?? [:]
    }

    func add(_ deltas: [String: InterfaceCounters], at date: Date, calendar: Calendar = .current) {
        guard !deltas.isEmpty else { return }
        let key = Self.dayKey(date, calendar: calendar)
        var day = days[key] ?? [:]
        for (name, delta) in deltas where delta.total > 0 {
            day[name, default: .zero] = day[name, default: .zero] + delta
        }
        days[key] = day
        isDirty = true
    }

    func totals(for period: BandwidthPeriod, now: Date = Date(),
                calendar: Calendar = .current) -> [String: InterfaceCounters] {
        Self.totals(for: period, in: days, now: now, calendar: calendar)
    }

    /// Writes to `UserDefaults` if anything changed, pruning old days first.
    func flush(now: Date = Date(), calendar: Calendar = .current) {
        guard isDirty else { return }
        days = Self.pruned(days, now: now, calendar: calendar)
        if let data = try? JSONEncoder().encode(days) { defaults.set(data, forKey: K.days) }
        isDirty = false
    }

    func reset() {
        days = [:]
        defaults.removeObject(forKey: K.days)
        isDirty = false
    }

    // MARK: - Pure helpers

    /// Zero-padded, so keys sort chronologically as plain strings.
    nonisolated static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Sums every day of `period` up to and including `now`'s day.
    nonisolated static func totals(for period: BandwidthPeriod, in days: Days, now: Date,
                                   calendar: Calendar) -> [String: InterfaceCounters] {
        let start: Date
        switch period {
        case .today: start = calendar.startOfDay(for: now)
        case .thisWeek: start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        case .thisMonth: start = calendar.dateInterval(of: .month, for: now)?.start ?? now
        }
        let first = dayKey(start, calendar: calendar)
        let last = dayKey(now, calendar: calendar)

        var result: [String: InterfaceCounters] = [:]
        for (key, interfaces) in days where key >= first && key <= last {
            for (name, counters) in interfaces {
                result[name, default: .zero] = result[name, default: .zero] + counters
            }
        }
        return result
    }

    nonisolated static func pruned(_ days: Days, now: Date, calendar: Calendar) -> Days {
        guard let cutoff = calendar.date(byAdding: .day, value: -retainedDays, to: now) else { return days }
        let oldest = dayKey(cutoff, calendar: calendar)
        return days.filter { $0.key > oldest }
    }

    private enum K {
        static let days = "bandwidth.dailyTotals"
    }
}
