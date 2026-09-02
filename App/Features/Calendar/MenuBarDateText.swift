import Foundation

/// The text shown beside the menu bar's day-number glyph.
///
/// Pure and `nonisolated`, in the shape of `KeepAwakeService.format(remaining:)`
/// — it stays off the main actor and is testable without a status item.
enum MenuBarDateText {
    /// - Returns: the formatted date, or `""` when the format asks for nothing
    ///   beyond the glyph.
    nonisolated static func text(for date: Date,
                                 format: MenuBarDateFormat,
                                 custom: String = "",
                                 locale: Locale = .current,
                                 timeZone: TimeZone = .current) -> String {
        switch format {
        case .dayNumberOnly:
            return ""
        case .weekday:
            return templated("EEE", date, locale, timeZone)
        case .monthDay:
            return templated("MMMd", date, locale, timeZone)
        case .weekdayMonthDay:
            return templated("EEEMMMd", date, locale, timeZone)
        case .monthDayWeekday:
            // Deliberately a fixed pattern, not a template: the whole point of
            // this option is the month-first "Sep 2., Wed" order, which a
            // template would reorder per region.
            return formatted(pattern: "MMM d., EEE", date, locale, timeZone)
        case .custom:
            let text = formatted(pattern: custom, date, locale, timeZone)
            // An empty or nonsense pattern would silently blank the menu bar;
            // fall back to something that still reads as a date.
            return text.isEmpty ? templated("MMMd", date, locale, timeZone) : text
        }
    }

    /// Locale-reordered: the fields are requested, the region decides the order.
    private nonisolated static func templated(_ template: String, _ date: Date,
                                              _ locale: Locale, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    private nonisolated static func formatted(pattern: String, _ date: Date,
                                              _ locale: Locale, _ timeZone: TimeZone) -> String {
        guard !pattern.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
