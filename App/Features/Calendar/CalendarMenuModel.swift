import Combine
import Foundation

/// State behind the calendar at the top of the menu: which month is on screen,
/// which day is selected, and what the grid knows about events.
///
/// The menu is torn down and rebuilt on every open, but this object is not —
/// `MenuBarController` keeps it so the view identity (and its SwiftUI state)
/// survives. `reset()` is what puts it back to "today" when the menu opens.
@MainActor
final class CalendarMenuModel: ObservableObject {
    /// Any day inside the month being displayed.
    @Published private(set) var visibleMonth: Date
    /// Start of the selected day; the event list follows it.
    @Published private(set) var selectedDay: Date
    @Published private(set) var days: [CalendarDay] = []
    /// Start-of-day dates in the visible grid that have at least one event.
    @Published private(set) var daysWithEvents: Set<Date> = []

    /// Called whenever the selected day changes, so the controller can swap the
    /// event rows underneath while the menu is open.
    var onSelectionChanged: (() -> Void)?

    private var calendar: Calendar
    private var cancellables: Set<AnyCancellable> = []

    init(settings: CalendarSettings = .shared, now: Date = Date()) {
        calendar = settings.displayCalendar
        visibleMonth = now
        selectedDay = calendar.startOfDay(for: now)
        rebuild()

        // The first-day-of-week override changes the grid's shape.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.calendar = CalendarSettings.shared.displayCalendar
                self?.rebuild()
            }
            .store(in: &cancellables)
    }

    var monthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: visibleMonth)
    }

    var weekdaySymbols: [String] { CalendarGrid.weekdaySymbols(calendar: calendar) }
    var weekNumbers: [Int] { CalendarGrid.weekNumbers(for: days, calendar: calendar) }

    /// True when the grid is showing a month other than the one we are in.
    var isShowingOtherMonth: Bool {
        !calendar.isDate(visibleMonth, equalTo: Date(), toGranularity: .month)
    }

    // MARK: - Navigation

    /// Back to this month with today selected — what opening the menu should show.
    func reset(now: Date = Date()) {
        calendar = CalendarSettings.shared.displayCalendar
        visibleMonth = now
        select(calendar.startOfDay(for: now), notify: false)
        rebuild()
    }

    func showPreviousMonth() { shiftMonth(by: -1) }
    func showNextMonth() { shiftMonth(by: 1) }

    func goToToday() { reset() ; onSelectionChanged?() }

    func select(_ day: Date, notify: Bool = true) {
        let start = calendar.startOfDay(for: day)
        guard start != selectedDay else { return }
        selectedDay = start
        if notify { onSelectionChanged?() }
    }

    /// Selecting a day outside the visible month pages to it, the way the system
    /// calendar does.
    func selectAndFollow(_ day: CalendarDay) {
        if !day.isInMonth {
            visibleMonth = day.date
            rebuild()
        }
        select(day.date)
    }

    private func shiftMonth(by months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: visibleMonth) else { return }
        visibleMonth = next
        rebuild()
    }

    // MARK: - Contents

    private func rebuild() {
        days = CalendarGrid.days(inMonthOf: visibleMonth, calendar: calendar, today: Date())
        reloadEventMarks()
    }

    /// Overridden in step with `CalendarEventsService`; a no-op without access.
    func reloadEventMarks() {
        daysWithEvents = []
    }
}
