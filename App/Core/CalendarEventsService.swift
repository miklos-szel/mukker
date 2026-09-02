import AppKit
import Combine
import EventKit
import Foundation

/// One event from the system calendars, flattened so nothing above this file has
/// to hold an `EKEvent` (or import EventKit at all).
struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarID: String
    let calendarColor: NSColor
}

/// The only thing in the app that talks to EventKit. Read-only: it lists what is
/// already in the user's calendars and never creates, edits or stores anything.
///
/// The `EKEventStore` is created **lazily and only once access has been granted**
/// — instantiating one and querying it is what triggers the system prompt, and
/// the prompt belongs to the Permissions pane, not to opening a menu.
@MainActor
final class CalendarEventsService: ObservableObject {
    static let shared = CalendarEventsService()

    private var store: EKEventStore?
    private var cancellables: Set<AnyCancellable> = []
    /// One grid's worth of marks, thrown away whenever the calendars change.
    private var markCache: (interval: DateInterval, days: Set<Date>)?

    private init() {
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.markCache = nil
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Nil until access exists, which is what keeps us from prompting by accident.
    private var activeStore: EKEventStore? {
        guard hasAccess else { return nil }
        if let store { return store }
        let store = EKEventStore()
        self.store = store
        return store
    }

    /// Forgets the cached store and marks — call after the grant changes, so the
    /// first fetch after granting doesn't come back empty from a stale store.
    func reset() {
        store = nil
        markCache = nil
        objectWillChange.send()
    }

    // MARK: - Queries

    /// Every event calendar, for the checkbox list in Settings.
    func allCalendars() -> [EKCalendar] {
        guard let activeStore else { return [] }
        return activeStore.calendars(for: .event)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The selected day's events, all-day ones first and then in start order.
    func events(on day: Date, calendar: Calendar) -> [CalendarEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events(in: DateInterval(start: start, end: end)).sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    /// Which days in the visible grid have at least one event — one query for the
    /// whole month, so paging costs a single fetch rather than 42.
    func daysWithEvents(in interval: DateInterval, calendar: Calendar) -> Set<Date> {
        if let markCache, markCache.interval == interval { return markCache.days }
        var days: Set<Date> = []
        for event in events(in: interval) {
            var day = calendar.startOfDay(for: max(event.start, interval.start))
            let last = min(event.end, interval.end)
            // An event can span days; mark every one it touches.
            while day < last {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            // A zero-length event ends exactly where it starts, so the loop above
            // never runs for it.
            if event.start == event.end { days.insert(calendar.startOfDay(for: event.start)) }
        }
        markCache = (interval, days)
        return days
    }

    private func events(in interval: DateInterval) -> [CalendarEvent] {
        guard let activeStore else { return [] }
        let hidden = Set(CalendarSettings.shared.hiddenCalendarIDs)
        let calendars = activeStore.calendars(for: .event)
            .filter { !hidden.contains($0.calendarIdentifier) }
        // An empty array would mean "search nothing"; nil means "search all", so
        // the difference matters when the user has hidden every calendar.
        guard !calendars.isEmpty else { return [] }

        let predicate = activeStore.predicateForEvents(withStart: interval.start,
                                                       end: interval.end,
                                                       calendars: calendars)
        return activeStore.events(matching: predicate).map { event in
            CalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "",
                start: event.startDate ?? interval.start,
                end: event.endDate ?? interval.start,
                isAllDay: event.isAllDay,
                calendarID: event.calendar?.calendarIdentifier ?? "",
                calendarColor: event.calendar?.color ?? .secondaryLabelColor)
        }
    }
}
