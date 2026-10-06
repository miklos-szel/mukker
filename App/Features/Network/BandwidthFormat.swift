import Foundation

/// Text for the menu bar rate and the Network submenu's totals. Pure and
/// `nonisolated`, like `MenuBarDateText`, so it is testable without a status item.
enum BandwidthFormat {
    /// The two rates, arrows included (`↓1,1`, `↑0,3`), in one shared unit
    /// chosen from the larger of them so the pair always reads at the same
    /// scale. Each number is at most three digits — one decimal below 10, whole
    /// numbers above — which is what lets `MenuBarBandwidthBadge` lay them out
    /// in fixed-width columns.
    nonisolated static func menuBarParts(down: Double, up: Double,
                                         locale: Locale = .current) -> (down: String, up: String, unit: String) {
        let (divisor, unit) = rateUnit(for: max(down, up, 0))
        return ("↓" + number(down / divisor, locale: locale),
                "↑" + number(up / divisor, locale: locale), unit)
    }

    nonisolated static func rateUnit(for bitsPerSecond: Double) -> (divisor: Double, unit: String) {
        // Thresholds sit a rounding step below the next unit, so 999,96 Kbps
        // reads "1,0 Mbps" rather than a four-digit "1000 Kbps".
        if bitsPerSecond >= 999.5e6 { return (1e9, "Gbps") }
        if bitsPerSecond >= 999.5e3 { return (1e6, "Mbps") }
        return (1e3, "Kbps")
    }

    private nonisolated static func number(_ value: Double, locale: Locale) -> String {
        let value = min(max(value, 0), 999)
        let text = value < 9.95
            ? value.formatted(.number.precision(.fractionLength(1)).locale(locale))
            : value.formatted(.number.precision(.fractionLength(0)).grouping(.never).locale(locale))
        return text
    }

    /// A row of the totals table: ↓, ↑ and the sum, all in the unit the sum
    /// needs, with the unit written once after the sum (`0,87  0,27  1,13 GB`).
    nonisolated static func volumeParts(received: UInt64, sent: UInt64,
                                        locale: Locale = .current)
        -> (received: String, sent: String, total: String) {
        let total = received &+ sent
        let units: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "KB")]
        guard let (divisor, unit) = units.first(where: { Double(total) >= $0.0 * 0.995 }) else {
            func bytes(_ value: UInt64) -> String { value.formatted(.number.locale(locale)) }
            return (bytes(received), bytes(sent), "\(bytes(total)) B")
        }
        func scaled(_ value: UInt64) -> String {
            (Double(value) / divisor).formatted(.number.precision(.fractionLength(2)).locale(locale))
        }
        return (scaled(received), scaled(sent), "\(scaled(total)) \(unit)")
    }
}
