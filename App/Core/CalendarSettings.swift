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

    /// Play a sound at the top of every hour. Off by default — an app that
    /// starts making noise on its own is a surprise nobody asked for.
    @Published var hourlyChimeEnabled: Bool {
        didSet { defaults.set(hourlyChimeEnabled, forKey: K.hourlyChime) }
    }

    /// Name of a system sound (`/System/Library/Sounds`), as `NSSound(named:)`
    /// takes it. A name that no longer resolves falls back at play time rather
    /// than here, so a macOS release dropping a sound doesn't rewrite the
    /// user's choice behind their back.
    @Published var hourlyChimeSound: String {
        didSet { defaults.set(hourlyChimeSound, forKey: K.hourlyChimeSound) }
    }

    /// First and last hour that chime, inclusive. `start > end` wraps past
    /// midnight — see `isChimeHour(_:start:end:)`.
    @Published var chimeStartHour: Int {
        didSet { defaults.set(chimeStartHour, forKey: K.chimeStart) }
    }

    @Published var chimeEndHour: Int {
        didSet { defaults.set(chimeEndHour, forKey: K.chimeEnd) }
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
        hourlyChimeEnabled = defaults.bool(forKey: K.hourlyChime)
        hourlyChimeSound = defaults.string(forKey: K.hourlyChimeSound) ?? Self.defaultChimeSound
        chimeStartHour = Self.clampHour(defaults.object(forKey: K.chimeStart) as? Int ?? 9)
        chimeEndHour = Self.clampHour(defaults.object(forKey: K.chimeEnd) as? Int ?? 22)
    }

    /// The calendar every date calculation in the feature goes through, so the
    /// first-day-of-week override applies in one place.
    var displayCalendar: Calendar {
        var calendar = Calendar.current
        if firstWeekday != .system { calendar.firstWeekday = firstWeekday.rawValue }
        return calendar
    }

    /// Whether `hour` falls inside the active range. Inclusive at both ends, and
    /// `start > end` means the range wraps past midnight (22…7 is the evening
    /// *and* the small hours). Pure, so the schedule's one real decision is
    /// testable without a clock.
    nonisolated static func isChimeHour(_ hour: Int, start: Int, end: Int) -> Bool {
        let hour = clampHour(hour), start = clampHour(start), end = clampHour(end)
        return start <= end ? (hour >= start && hour <= end) : (hour >= start || hour <= end)
    }

    /// The whole gate `HourlyChimeService` applies when its timer fires.
    func shouldChime(at date: Date) -> Bool {
        guard hourlyChimeEnabled else { return false }
        let hour = Calendar.current.component(.hour, from: date)
        return Self.isChimeHour(hour, start: chimeStartHour, end: chimeEndHour)
    }

    nonisolated static func clampHour(_ hour: Int) -> Int { min(max(hour, 0), 23) }

    static let defaultChimeSound = "Submarine"

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
        static let hourlyChime = "calendar.hourlyChime"
        static let hourlyChimeSound = "calendar.hourlyChimeSound"
        static let chimeStart = "calendar.hourlyChimeStartHour"
        static let chimeEnd = "calendar.hourlyChimeEndHour"
    }
}
