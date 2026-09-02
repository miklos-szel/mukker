import Foundation

/// One cell of the month grid.
struct CalendarDay: Identifiable, Equatable {
    /// Start of the day, in the grid's calendar — also the identity used to
    /// match a day against the set of days that have events.
    let date: Date
    let day: Int
    /// False for the leading/trailing days borrowed from the neighbouring months.
    let isInMonth: Bool
    let isToday: Bool

    var id: Date { date }
}

/// The month grid's pure geometry — no view, no state, no `Date()`.
///
/// The grid is **always six rows**. A month needs five or six depending on where
/// it starts, and a grid that changed height would resize the menu while paging.
enum CalendarGrid {
    static let rows = 6
    static let columns = 7
    static var cellCount: Int { rows * columns }

    /// The six weeks containing `date`'s month, starting on the calendar's
    /// `firstWeekday`.
    nonisolated static func days(inMonthOf date: Date,
                                 calendar: Calendar,
                                 today: Date) -> [CalendarDay] {
        let monthComponents = calendar.dateComponents([.year, .month], from: date)
        guard let startOfMonth = calendar.date(from: monthComponents) else { return [] }

        // How far back the grid reaches into the previous month.
        let weekday = calendar.component(.weekday, from: startOfMonth)
        let lead = (weekday - calendar.firstWeekday + columns) % columns
        guard let gridStart = calendar.date(byAdding: .day, value: -lead, to: startOfMonth) else {
            return []
        }

        let todayStart = calendar.startOfDay(for: today)
        return (0..<cellCount).compactMap { offset in
            guard let raw = calendar.date(byAdding: .day, value: offset, to: gridStart) else {
                return nil
            }
            // Re-normalising each day absorbs DST transitions, which would
            // otherwise drift the grid by an hour and land on the wrong day.
            let start = calendar.startOfDay(for: raw)
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            return CalendarDay(
                date: start,
                day: parts.day ?? 0,
                isInMonth: parts.month == monthComponents.month && parts.year == monthComponents.year,
                isToday: start == todayStart)
        }
    }

    /// Single-letter weekday headers, rotated to the calendar's `firstWeekday`.
    nonisolated static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.count == columns else { return symbols }
        let shift = calendar.firstWeekday - 1
        return (0..<columns).map { symbols[($0 + shift) % columns] }
    }

    /// The ISO-style week number for each of the six rows.
    nonisolated static func weekNumbers(for days: [CalendarDay], calendar: Calendar) -> [Int] {
        stride(from: 0, to: days.count, by: columns).map {
            calendar.component(.weekOfYear, from: days[$0].date)
        }
    }

    /// The span the grid covers — one query's worth of range for event lookups.
    nonisolated static func interval(for days: [CalendarDay], calendar: Calendar) -> DateInterval? {
        guard let first = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last.date) else { return nil }
        return DateInterval(start: first.date, end: end)
    }
}
