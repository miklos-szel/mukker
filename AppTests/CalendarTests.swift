import XCTest
@testable import AppCore

/// The pure half of the menu bar calendar: the month grid's geometry, the text
/// beside the bar glyph, and the settings behind both.
///
/// Deliberately not covered: `CalendarEventsService`, which needs a real
/// Calendar grant and the user's own events, and the `NSStatusItem`/`NSMenu`
/// half, which needs a running UI. Both are verified by hand.
final class CalendarGridTests: XCTestCase {
    /// Fixed so the tests don't depend on the machine's region or time zone.
    private func makeCalendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    // MARK: - Grid shape

    func testGridIsAlwaysSixWeeks() {
        let calendar = makeCalendar(firstWeekday: 2)
        // February 2026 fits in four rows once and five rows another year; the
        // grid must not change height either way.
        for month in 1...12 {
            let days = CalendarGrid.days(inMonthOf: date(2026, month, 15, in: calendar),
                                         calendar: calendar,
                                         today: date(2026, month, 15, in: calendar))
            XCTAssertEqual(days.count, 42, "month \(month) should still be a 6x7 grid")
        }
    }

    func testGridStartsOnTheCalendarsFirstWeekday() {
        for firstWeekday in [1, 2, 7] {
            let calendar = makeCalendar(firstWeekday: firstWeekday)
            let days = CalendarGrid.days(inMonthOf: date(2026, 9, 1, in: calendar),
                                         calendar: calendar,
                                         today: date(2026, 9, 2, in: calendar))
            let weekday = calendar.component(.weekday, from: days[0].date)
            XCTAssertEqual(weekday, firstWeekday,
                           "first cell should be the week's first day, not the month's")
        }
    }

    /// September 2026 starts on a Tuesday, so a Monday-first grid borrows
    /// exactly one day (31 August) and a Sunday-first grid borrows two.
    func testLeadingDaysComeFromThePreviousMonth() {
        let monday = makeCalendar(firstWeekday: 2)
        let mondayGrid = CalendarGrid.days(inMonthOf: date(2026, 9, 1, in: monday),
                                           calendar: monday,
                                           today: date(2026, 9, 2, in: monday))
        XCTAssertEqual(mondayGrid.prefix(2).map(\.day), [31, 1])
        XCTAssertEqual(mondayGrid.prefix(2).map(\.isInMonth), [false, true])

        let sunday = makeCalendar(firstWeekday: 1)
        let sundayGrid = CalendarGrid.days(inMonthOf: date(2026, 9, 1, in: sunday),
                                           calendar: sunday,
                                           today: date(2026, 9, 2, in: sunday))
        XCTAssertEqual(sundayGrid.prefix(3).map(\.day), [30, 31, 1])
    }

    func testLeapYearFebruaryEndsOnTheTwentyNinth() {
        let calendar = makeCalendar(firstWeekday: 2)
        let days = CalendarGrid.days(inMonthOf: date(2028, 2, 10, in: calendar),
                                     calendar: calendar,
                                     today: date(2028, 2, 10, in: calendar))
        XCTAssertEqual(days.filter(\.isInMonth).map(\.day), Array(1...29))
    }

    func testNonLeapYearFebruaryEndsOnTheTwentyEighth() {
        let calendar = makeCalendar(firstWeekday: 2)
        let days = CalendarGrid.days(inMonthOf: date(2026, 2, 10, in: calendar),
                                     calendar: calendar,
                                     today: date(2026, 2, 10, in: calendar))
        XCTAssertEqual(days.filter(\.isInMonth).map(\.day), Array(1...28))
    }

    // MARK: - Today

    func testExactlyOneDayIsTodayWhenTodayIsOnScreen() {
        let calendar = makeCalendar(firstWeekday: 2)
        let today = date(2026, 9, 2, in: calendar)
        let days = CalendarGrid.days(inMonthOf: today, calendar: calendar, today: today)
        let marked = days.filter(\.isToday)
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(marked.first?.day, 2)
    }

    func testNoDayIsTodayWhenTheMonthIsFarAway() {
        let calendar = makeCalendar(firstWeekday: 2)
        let days = CalendarGrid.days(inMonthOf: date(2027, 5, 1, in: calendar),
                                     calendar: calendar,
                                     today: date(2026, 9, 2, in: calendar))
        XCTAssertTrue(days.allSatisfy { !$0.isToday })
    }

    /// The grid borrows days from the neighbouring months, so "today" can be one
    /// of those — it must still be marked.
    func testTodayIsMarkedEvenWhenBorrowedFromAnotherMonth() {
        let calendar = makeCalendar(firstWeekday: 2)
        let today = date(2026, 8, 31, in: calendar)
        let days = CalendarGrid.days(inMonthOf: date(2026, 9, 15, in: calendar),
                                     calendar: calendar, today: today)
        let marked = days.filter(\.isToday)
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(marked.first?.isInMonth, false)
    }

    /// A DST transition inside the grid must not shift the days by an hour and
    /// land the grid on the wrong dates.
    func testGridSurvivesADaylightSavingTransition() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Europe/Budapest") ?? .gmt
        calendar.firstWeekday = 2
        // Central European summer time ends on 25 October 2026.
        let october = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15)) ?? .distantPast
        let days = CalendarGrid.days(inMonthOf: october, calendar: calendar, today: october)
        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(days.filter(\.isInMonth).map(\.day), Array(1...31))
        for day in days {
            XCTAssertEqual(calendar.startOfDay(for: day.date), day.date,
                           "every cell should sit on a start-of-day boundary")
        }
    }

    // MARK: - Headers

    func testWeekdaySymbolsAreRotatedToTheFirstWeekday() {
        XCTAssertEqual(CalendarGrid.weekdaySymbols(calendar: makeCalendar(firstWeekday: 2)),
                       ["M", "T", "W", "T", "F", "S", "S"])
        XCTAssertEqual(CalendarGrid.weekdaySymbols(calendar: makeCalendar(firstWeekday: 1)),
                       ["S", "M", "T", "W", "T", "F", "S"])
    }

    func testWeekNumbersAreOnePerRow() {
        let calendar = makeCalendar(firstWeekday: 2)
        let days = CalendarGrid.days(inMonthOf: date(2026, 9, 1, in: calendar),
                                     calendar: calendar,
                                     today: date(2026, 9, 2, in: calendar))
        let numbers = CalendarGrid.weekNumbers(for: days, calendar: calendar)
        XCTAssertEqual(numbers.count, CalendarGrid.rows)
        XCTAssertEqual(Array(Set(numbers)).count, CalendarGrid.rows, "each row is its own week")
    }

    func testIntervalSpansTheWholeGrid() {
        let calendar = makeCalendar(firstWeekday: 2)
        let days = CalendarGrid.days(inMonthOf: date(2026, 9, 1, in: calendar),
                                     calendar: calendar,
                                     today: date(2026, 9, 2, in: calendar))
        let interval = CalendarGrid.interval(for: days, calendar: calendar)
        XCTAssertEqual(interval?.start, days.first?.date)
        // Exclusive end: one day past the last cell, so a query covers it fully.
        XCTAssertEqual(interval?.end, calendar.date(byAdding: .day, value: 1, to: days[41].date))
    }

    // MARK: - Month outline

    func testMonthSpanCoversExactlyTheAnchorMonth() {
        // September 2026 starts on a Tuesday: one borrowed day Monday-first, two
        // Sunday-first, and the span shifts by the same amount.
        let monday = makeCalendar(firstWeekday: 2)
        let mondayGrid = CalendarGrid.days(inMonthOf: date(2026, 9, 1, in: monday),
                                           calendar: monday,
                                           today: date(2026, 9, 2, in: monday))
        XCTAssertEqual(CalendarGrid.monthSpan(in: mondayGrid), 1...30)

        let sunday = makeCalendar(firstWeekday: 1)
        let sundayGrid = CalendarGrid.days(inMonthOf: date(2026, 9, 1, in: sunday),
                                           calendar: sunday,
                                           today: date(2026, 9, 2, in: sunday))
        XCTAssertEqual(CalendarGrid.monthSpan(in: sundayGrid), 2...31)

        // February 2026 starts on the grid's first day and is exactly four weeks.
        let february = CalendarGrid.days(inMonthOf: date(2026, 2, 1, in: sunday),
                                         calendar: sunday,
                                         today: date(2026, 2, 2, in: sunday))
        XCTAssertEqual(CalendarGrid.monthSpan(in: february), 0...27)

        XCTAssertNil(CalendarGrid.monthSpan(in: []))
    }

    /// The eight-corner case: both the first and the last row are partial, so the
    /// outline steps in at the top left and out at the bottom right.
    func testMonthOutlineStepsAroundAPartialFirstAndLastRow() {
        let cell = CGSize(width: 10, height: 10)
        let corners = MonthOutlineShape.corners(span: 1...30, cell: cell)
        XCTAssertEqual(corners, [CGPoint(x: 10, y: 0),
                                 CGPoint(x: 70, y: 0),
                                 CGPoint(x: 70, y: 40),
                                 CGPoint(x: 30, y: 40),
                                 CGPoint(x: 30, y: 50),
                                 CGPoint(x: 0, y: 50),
                                 CGPoint(x: 0, y: 10),
                                 CGPoint(x: 10, y: 10)])
    }

    func testMonthOutlineCollapsesWhenARowIsFull() {
        let cell = CGSize(width: 10, height: 10)
        // Four whole weeks: a plain rectangle, no steps.
        XCTAssertEqual(MonthOutlineShape.corners(span: 0...27, cell: cell),
                       [CGPoint(x: 0, y: 0), CGPoint(x: 70, y: 0),
                        CGPoint(x: 70, y: 40), CGPoint(x: 0, y: 40)])
        // Starts on the first column, ends mid-row: one step, six corners.
        XCTAssertEqual(MonthOutlineShape.corners(span: 0...30, cell: cell),
                       [CGPoint(x: 0, y: 0), CGPoint(x: 70, y: 0),
                        CGPoint(x: 70, y: 40), CGPoint(x: 30, y: 40),
                        CGPoint(x: 30, y: 50), CGPoint(x: 0, y: 50)])
    }

    /// Every corner has to land on a cell boundary, or the frame would cut
    /// through a day number.
    func testMonthOutlineCornersLandOnCellBoundaries() {
        let calendar = makeCalendar(firstWeekday: 2)
        let cell = CGSize(width: 23, height: 23)
        for month in 1...12 {
            let days = CalendarGrid.days(inMonthOf: date(2026, month, 15, in: calendar),
                                         calendar: calendar,
                                         today: date(2026, month, 15, in: calendar))
            guard let span = CalendarGrid.monthSpan(in: days) else {
                return XCTFail("month \(month) has no in-month days")
            }
            for corner in MonthOutlineShape.corners(span: span, cell: cell) {
                XCTAssertEqual(corner.x.truncatingRemainder(dividingBy: cell.width), 0,
                               "month \(month) corner \(corner) is off the column grid")
                XCTAssertEqual(corner.y.truncatingRemainder(dividingBy: cell.height), 0,
                               "month \(month) corner \(corner) is off the row grid")
            }
        }
    }
}

// MARK: -

final class MenuBarDateTextTests: XCTestCase {
    private let locale = Locale(identifier: "en_US_POSIX")
    private let timeZone = TimeZone(identifier: "UTC") ?? .gmt

    private var wednesday: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 2)) ?? .distantPast
    }

    private func text(_ format: MenuBarDateFormat, custom: String = "") -> String {
        MenuBarDateText.text(for: wednesday, format: format, custom: custom,
                             locale: locale, timeZone: timeZone)
    }

    /// The glyph already carries the number, so this format adds nothing.
    func testDayNumberOnlyAddsNoText() {
        XCTAssertEqual(text(.dayNumberOnly), "")
    }

    func testWeekdayAndMonthDayPresets() {
        XCTAssertEqual(text(.weekday), "Wed")
        XCTAssertEqual(text(.monthDay), "Sep 2")
        XCTAssertTrue(text(.weekdayMonthDay).contains("Wed"))
        XCTAssertTrue(text(.weekdayMonthDay).contains("Sep"))
    }

    /// This preset exists for its fixed order, so it must not be reordered.
    func testMonthDayWeekdayKeepsItsOrder() {
        XCTAssertEqual(text(.monthDayWeekday), "Sep 2., Wed")
    }

    func testCustomFormatIsUsedVerbatim() {
        XCTAssertEqual(text(.custom, custom: "yyyy-MM-dd"), "2026-09-02")
    }

    /// An empty custom pattern would silently blank the menu bar.
    func testEmptyCustomFormatFallsBackToADate() {
        XCTAssertEqual(text(.custom, custom: ""), "Sep 2")
    }
}

// MARK: -

@MainActor
final class CalendarSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "AppTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testDefaults() {
        let settings = CalendarSettings(defaults: makeDefaults())
        XCTAssertTrue(settings.showsDateInMenuBar)
        XCTAssertEqual(settings.menuBarFormat, .dayNumberOnly)
        XCTAssertEqual(settings.firstWeekday, .system)
        XCTAssertFalse(settings.showsWeekNumbers)
        XCTAssertTrue(settings.showsEvents)
        XCTAssertEqual(settings.maxEventsShown, 8)
        XCTAssertTrue(settings.hiddenCalendarIDs.isEmpty)
        XCTAssertFalse(settings.hourlyChimeEnabled)
        XCTAssertEqual(settings.hourlyChimeSound, "Submarine")
        XCTAssertEqual(settings.chimeStartHour, 9)
        XCTAssertEqual(settings.chimeEndHour, 22)
    }

    func testSettingsPersistAcrossInstances() {
        let defaults = makeDefaults()
        let first = CalendarSettings(defaults: defaults)
        first.showsDateInMenuBar = false
        first.menuBarFormat = .monthDayWeekday
        first.customDateFormat = "yyyy-MM-dd"
        first.firstWeekday = .monday
        first.showsWeekNumbers = true
        first.showsEvents = false
        first.maxEventsShown = 3
        first.hourlyChimeEnabled = true
        first.hourlyChimeSound = "Glass"
        first.chimeStartHour = 7
        first.chimeEndHour = 19

        let second = CalendarSettings(defaults: defaults)
        XCTAssertFalse(second.showsDateInMenuBar)
        XCTAssertEqual(second.menuBarFormat, .monthDayWeekday)
        XCTAssertEqual(second.customDateFormat, "yyyy-MM-dd")
        XCTAssertEqual(second.firstWeekday, .monday)
        XCTAssertTrue(second.showsWeekNumbers)
        XCTAssertFalse(second.showsEvents)
        XCTAssertEqual(second.maxEventsShown, 3)
        XCTAssertTrue(second.hourlyChimeEnabled)
        XCTAssertEqual(second.hourlyChimeSound, "Glass")
        XCTAssertEqual(second.chimeStartHour, 7)
        XCTAssertEqual(second.chimeEndHour, 19)
    }

    func testUnknownStoredFormatFallsBackToTheDefault() {
        let defaults = makeDefaults()
        defaults.set("somethingFromANewerBuild", forKey: "calendar.menuBarFormat")
        XCTAssertEqual(CalendarSettings(defaults: defaults).menuBarFormat, .dayNumberOnly)
    }

    /// The list stores what to *hide*, so a calendar nobody has touched is shown.
    func testHiddenCalendarsRoundTrip() {
        let defaults = makeDefaults()
        let settings = CalendarSettings(defaults: defaults)
        XCTAssertFalse(settings.isCalendarHidden("work"))

        settings.setCalendar("work", hidden: true)
        settings.setCalendar("work", hidden: true)  // idempotent
        XCTAssertEqual(settings.hiddenCalendarIDs, ["work"])
        XCTAssertTrue(CalendarSettings(defaults: defaults).isCalendarHidden("work"))

        settings.setCalendar("work", hidden: false)
        XCTAssertTrue(settings.hiddenCalendarIDs.isEmpty)
    }

    func testFirstWeekdayOverridesTheSystemCalendar() {
        let settings = CalendarSettings(defaults: makeDefaults())
        settings.firstWeekday = .saturday
        XCTAssertEqual(settings.displayCalendar.firstWeekday, 7)

        settings.firstWeekday = .system
        XCTAssertEqual(settings.displayCalendar.firstWeekday, Calendar.current.firstWeekday)
    }
}

// MARK: -

/// The pure halves of the hourly chime: which hours are in range, and when the
/// next chime lands. Playback itself (CoreAudio's default output device, and
/// `NSSound`) needs real hardware and is verified by hand.
@MainActor
final class HourlyChimeTests: XCTestCase {
    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    // MARK: - Active hours

    func testActiveHoursAreInclusiveAtBothEnds() {
        XCTAssertTrue(CalendarSettings.isChimeHour(9, start: 9, end: 22))
        XCTAssertTrue(CalendarSettings.isChimeHour(22, start: 9, end: 22))
        XCTAssertTrue(CalendarSettings.isChimeHour(15, start: 9, end: 22))
        XCTAssertFalse(CalendarSettings.isChimeHour(8, start: 9, end: 22))
        XCTAssertFalse(CalendarSettings.isChimeHour(23, start: 9, end: 22))
    }

    /// A range whose end is before its start covers the night, not nothing.
    func testActiveHoursWrapPastMidnight() {
        for hour in [22, 23, 0, 3, 7] {
            XCTAssertTrue(CalendarSettings.isChimeHour(hour, start: 22, end: 7),
                          "\(hour):00 should be inside 22…7")
        }
        for hour in [8, 12, 21] {
            XCTAssertFalse(CalendarSettings.isChimeHour(hour, start: 22, end: 7),
                           "\(hour):00 should be outside 22…7")
        }
    }

    func testSingleHourRange() {
        XCTAssertTrue(CalendarSettings.isChimeHour(13, start: 13, end: 13))
        XCTAssertFalse(CalendarSettings.isChimeHour(14, start: 13, end: 13))
    }

    func testOutOfRangeHoursClamp() {
        XCTAssertEqual(CalendarSettings.clampHour(-3), 0)
        XCTAssertEqual(CalendarSettings.clampHour(99), 23)
        // A stored 24 clamps to 23 rather than making the range empty.
        XCTAssertTrue(CalendarSettings.isChimeHour(23, start: 0, end: 24))
    }

    func testShouldChimeNeedsTheSwitchOn() {
        let settings = CalendarSettings(defaults: UserDefaults(suiteName: "AppTests-\(UUID().uuidString)")!)
        let hour = Calendar.current.component(.hour, from: Date())
        settings.chimeStartHour = hour
        settings.chimeEndHour = hour

        XCTAssertFalse(settings.shouldChime(at: Date()), "off by default")
        settings.hourlyChimeEnabled = true
        XCTAssertTrue(settings.shouldChime(at: Date()))
    }

    // MARK: - Schedule

    func testNextChimeIsTheTopOfTheComingHour() {
        let calendar = makeCalendar()
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2,
                                                     hour: 14, minute: 37, second: 12))!
        let next = HourlyChimeService.nextChime(after: now, calendar: calendar)
        XCTAssertEqual(next, calendar.date(from: DateComponents(year: 2026, month: 9, day: 2,
                                                                hour: 15, minute: 0, second: 1)))
    }

    /// The second-past-the-hour offset is what keeps a timer from firing a hair
    /// early and reading the *previous* hour.
    func testNextChimeSkipsTheHourItIsAlreadyPast() {
        let calendar = makeCalendar()
        let atTheHour = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2,
                                                           hour: 15, minute: 0, second: 1))!
        let next = HourlyChimeService.nextChime(after: atTheHour, calendar: calendar)
        XCTAssertEqual(next, calendar.date(from: DateComponents(year: 2026, month: 9, day: 2,
                                                                hour: 16, minute: 0, second: 1)))
    }

    func testNextChimeCrossesMidnight() {
        let calendar = makeCalendar()
        let lateNight = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2,
                                                           hour: 23, minute: 59, second: 30))!
        let next = HourlyChimeService.nextChime(after: lateNight, calendar: calendar)
        XCTAssertEqual(next, calendar.date(from: DateComponents(year: 2026, month: 9, day: 3,
                                                                hour: 0, minute: 0, second: 1)))
    }

    func testEveryMinuteIntervalIsDebugOnlyButComputesTheNextMinute() {
        let calendar = makeCalendar()
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2,
                                                     hour: 14, minute: 37, second: 12))!
        let next = HourlyChimeService.nextChime(after: now, calendar: calendar,
                                                interval: .everyMinute)
        XCTAssertEqual(next, calendar.date(from: DateComponents(year: 2026, month: 9, day: 2,
                                                                hour: 14, minute: 38, second: 1)))
    }

    func testAvailableSoundsIncludeSomethingPlayable() {
        let sounds = HourlyChimeService.availableSounds
        XCTAssertFalse(sounds.isEmpty)
        XCTAssertEqual(sounds, sounds.sorted())
    }
}
