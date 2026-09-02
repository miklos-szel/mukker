import SwiftUI

/// The month calendar that sits at the top of the menu bar menu, hosted in an
/// `NSMenuItem`'s view.
///
/// Everything it draws comes from `CalendarMenuModel`; the grid geometry is
/// `CalendarGrid`'s. Read-only: paging and selecting a day are the only
/// interactions, and selecting a day is what the event rows below follow.
struct CalendarMenuView: View {
    @ObservedObject var model: CalendarMenuModel
    @ObservedObject private var settings = CalendarSettings.shared

    private let cell = CGSize(width: 30, height: 25)
    private let weekNumberWidth: CGFloat = 22

    init(model: CalendarMenuModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            grid
        }
        .padding(.horizontal, 13)
        .padding(.top, 6)
        .padding(.bottom, 9)
        .frame(width: 13 * 2 + cell.width * CGFloat(CalendarGrid.columns)
               + (settings.showsWeekNumbers ? weekNumberWidth : 0),
               alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            Text(model.monthTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            pager("chevron.left", help: "Previous month") { model.showPreviousMonth() }
            pager("circle.fill", size: 7, help: "Today") { model.goToToday() }
                .opacity(model.isShowingOtherMonth ? 1 : 0.35)
            pager("chevron.right", help: "Next month") { model.showNextMonth() }
        }
    }

    private func pager(_ symbol: String, size: CGFloat = 10,
                       help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Grid

    private var grid: some View {
        VStack(spacing: 1) {
            HStack(spacing: 0) {
                if settings.showsWeekNumbers {
                    Color.clear.frame(width: weekNumberWidth, height: 1)
                }
                ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: cell.width)
                }
            }
            .padding(.bottom, 2)

            ForEach(0..<CalendarGrid.rows, id: \.self) { row in
                HStack(spacing: 0) {
                    if settings.showsWeekNumbers {
                        Text(weekNumber(row))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .frame(width: weekNumberWidth)
                    }
                    ForEach(days(inRow: row)) { day in
                        dayCell(day)
                    }
                }
            }
        }
    }

    private func days(inRow row: Int) -> [CalendarDay] {
        let start = row * CalendarGrid.columns
        guard model.days.count >= start + CalendarGrid.columns else { return [] }
        return Array(model.days[start ..< start + CalendarGrid.columns])
    }

    private func weekNumber(_ row: Int) -> String {
        let numbers = model.weekNumbers
        return row < numbers.count ? String(numbers[row]) : ""
    }

    private func dayCell(_ day: CalendarDay) -> some View {
        let isSelected = day.date == model.selectedDay
        let hasEvents = model.daysWithEvents.contains(day.date)
        return Button {
            model.selectAndFollow(day)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(day.isToday ? Color.accentColor : .clear)
                    .padding(1.5)
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .padding(1.5)
                    .opacity(isSelected && !day.isToday ? 1 : 0)
                Text("\(day.day)")
                    .font(.system(size: 12, weight: day.isToday ? .semibold : .regular))
                    .foregroundStyle(foreground(for: day))
                // The event marker hangs below the number rather than displacing
                // it, so rows with and without events line up.
                Circle()
                    .fill(day.isToday ? Color.white : Color.accentColor)
                    .frame(width: 3, height: 3)
                    .offset(y: cell.height / 2 - 5)
                    .opacity(hasEvents ? 1 : 0)
            }
            .frame(width: cell.width, height: cell.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func foreground(for day: CalendarDay) -> Color {
        if day.isToday { return .white }
        return day.isInMonth ? .primary : .secondary.opacity(0.55)
    }
}
