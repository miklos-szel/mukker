import Combine
import Foundation

/// What the menu bar item shows next to the day-number glyph.
///
/// The presets go through `DateFormatter`'s *template* API wherever the field
/// order can be left to the locale. `monthDayWeekday` is the exception — it
/// pins the order because it exists specifically to reproduce the `Sep 2., Wed`
/// look, which a template would reorder per region.
enum MenuBarDateFormat: String, CaseIterable, Identifiable {
    /// Nothing but the glyph, which already carries the day number.
    case dayNumberOnly
    case weekday
    case monthDay
    case weekdayMonthDay
    case monthDayWeekday
    /// A raw `DateFormatter.dateFormat` string from `customDateFormat`.
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dayNumberOnly: return "Day number only"
        case .weekday: return "Weekday"
        case .monthDay: return "Month and day"
        case .weekdayMonthDay: return "Weekday, month and day"
        case .monthDayWeekday: return "Month, day and weekday"
        case .custom: return "Custom…"
        }
    }
}

/// Which day the calendar's week starts on.
enum FirstWeekdayOption: Int, CaseIterable, Identifiable {
    /// Follow the macOS region setting — what `Calendar.current` already says.
    case system = 0
    case sunday = 1
    case monday = 2
    case saturday = 7

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .system: return "System setting"
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .saturday: return "Saturday"
        }
    }
}

/// Preferences for the menu-bar date and the calendar behind it. `@Published` +
/// `didSet` over an injected `UserDefaults`, the same shape as
/// `WindowTilingSettings` and `KeepAwakeSettings`.
///
/// Note that the calendar list is stored as the calendars to **hide**, not the
/// ones to show: a calendar the user subscribes to later then appears by
/// default instead of silently going missing.
@MainActor
final class CalendarSettings: ObservableObject {
    static let shared = CalendarSettings()

    private let defaults: UserDefaults

    /// Replace the app glyph in the menu bar with the date. On by default.
    @Published var showsDateInMenuBar: Bool {
        didSet { defaults.set(showsDateInMenuBar, forKey: K.showsDate) }
    }

    /// Text shown next to the glyph. Nothing out of the box — the glyph already
    /// carries the day number.
    @Published var menuBarFormat: MenuBarDateFormat {
        didSet { defaults.set(menuBarFormat.rawValue, forKey: K.format) }
    }

    /// `DateFormatter` pattern used when `menuBarFormat` is `.custom`.
    @Published var customDateFormat: String {
        didSet { defaults.set(customDateFormat, forKey: K.customFormat) }
    }

    @Published var firstWeekday: FirstWeekdayOption {
        didSet { defaults.set(firstWeekday.rawValue, forKey: K.firstWeekday) }
    }

    @Published var showsWeekNumbers: Bool {
        didSet { defaults.set(showsWeekNumbers, forKey: K.weekNumbers) }
    }

    /// List the selected day's events under the calendar. On by default, but it
    /// stays inert until Calendar access is granted in Settings → Permissions.
    @Published var showsEvents: Bool {
        didSet { defaults.set(showsEvents, forKey: K.showsEvents) }
    }

    /// How many events to list before collapsing the rest into a "N more" row.
    @Published var maxEventsShown: Int {
        didSet { defaults.set(maxEventsShown, forKey: K.maxEvents) }
    }

    /// Calendar identifiers the user has switched off.
    @Published var hiddenCalendarIDs: [String] {
        didSet { defaults.set(hiddenCalendarIDs, forKey: K.hiddenCalendars) }
    }

    static let maximumEventsShown = 20

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `defaults.bool(forKey:)` cannot express default-on, hence the casts.
        showsDateInMenuBar = defaults.object(forKey: K.showsDate) as? Bool ?? true
        menuBarFormat = (defaults.string(forKey: K.format))
            .flatMap(MenuBarDateFormat.init(rawValue:)) ?? .dayNumberOnly
        customDateFormat = defaults.string(forKey: K.customFormat) ?? "E d MMM"
        firstWeekday = (defaults.object(forKey: K.firstWeekday) as? Int)
            .flatMap(FirstWeekdayOption.init(rawValue:)) ?? .system
        showsWeekNumbers = defaults.bool(forKey: K.weekNumbers)
        showsEvents = defaults.object(forKey: K.showsEvents) as? Bool ?? true
        maxEventsShown = (defaults.object(forKey: K.maxEvents) as? Int) ?? 8
        hiddenCalendarIDs = defaults.stringArray(forKey: K.hiddenCalendars) ?? []
    }

    /// The calendar every date calculation in the feature goes through, so the
    /// first-day-of-week override applies in one place.
    var displayCalendar: Calendar {
        var calendar = Calendar.current
        if firstWeekday != .system { calendar.firstWeekday = firstWeekday.rawValue }
        return calendar
    }

    func isCalendarHidden(_ identifier: String) -> Bool {
        hiddenCalendarIDs.contains(identifier)
    }

    func setCalendar(_ identifier: String, hidden: Bool) {
        if hidden {
            guard !hiddenCalendarIDs.contains(identifier) else { return }
            hiddenCalendarIDs.append(identifier)
        } else {
            hiddenCalendarIDs.removeAll { $0 == identifier }
        }
    }

    private enum K {
        static let showsDate = "calendar.showsDateInMenuBar"
        static let format = "calendar.menuBarFormat"
        static let customFormat = "calendar.customDateFormat"
        static let firstWeekday = "calendar.firstWeekday"
        static let weekNumbers = "calendar.showsWeekNumbers"
        static let showsEvents = "calendar.showsEvents"
        static let maxEvents = "calendar.maxEventsShown"
        static let hiddenCalendars = "calendar.hiddenCalendarIDs"
    }
}
