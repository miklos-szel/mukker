import EventKit
import SwiftUI

/// The menu bar calendar: what the bar item shows, how the grid is laid out, and
/// which calendars the event rows draw from.
///
/// The Calendar permission itself is not here — permissions are granted in
/// `PermissionsPane` and nowhere else — so the events section points at that tab
/// instead of offering its own button.
struct CalendarPane: View {
    @ObservedObject private var settings = CalendarSettings.shared
    @ObservedObject private var events = CalendarEventsService.shared
    @State private var hasCalendarAccess = false
    @State private var calendars: [EKCalendar] = []

    private let pollTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Show the date in the menu bar", isOn: $settings.showsDateInMenuBar)

                Group {
                    Picker("Next to the date", selection: $settings.menuBarFormat) {
                        ForEach(MenuBarDateFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)

                    if settings.menuBarFormat == .custom {
                        LabeledContent("Format") {
                            TextField("", text: $settings.customDateFormat)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                        }
                    }

                    LabeledContent("Preview") {
                        Text(preview.isEmpty ? "the day number alone" : preview)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.showsDateInMenuBar)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("The icon always carries today's day number. Turning the date off "
                     + "restores the plain \(Branding.name) icon. Custom formats use "
                     + "Unicode date patterns — d, EEE, MMM, yyyy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Calendar") {
                Picker("Week starts on", selection: $settings.firstWeekday) {
                    ForEach(FirstWeekdayOption.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                Toggle("Show week numbers", isOn: $settings.showsWeekNumbers)
            }

            Section {
                Toggle("List the selected day's events", isOn: $settings.showsEvents)

                Stepper(value: $settings.maxEventsShown,
                        in: 1...CalendarSettings.maximumEventsShown) {
                    LabeledContent("Show at most", value: "\(settings.maxEventsShown) events")
                }
                .disabled(!settings.showsEvents)
            } header: {
                Text("Events")
            } footer: {
                if !hasCalendarAccess {
                    Text("Calendar access has not been granted — grant it under "
                         + "Permissions and the events will appear.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if hasCalendarAccess {
                Section {
                    if calendars.isEmpty {
                        Text("No calendars found.").foregroundStyle(.secondary)
                    }
                    ForEach(calendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: binding(for: calendar)) {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(Color(nsColor: calendar.color ?? .secondaryLabelColor))
                                    .frame(width: 9, height: 9)
                                Text(calendar.title)
                                if let source = calendar.source?.title, !source.isEmpty {
                                    Text(source)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Include")
                } footer: {
                    Text("A calendar you subscribe to later is included automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.showsEvents)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(pollTimer) { _ in refresh() }
    }

    private var preview: String {
        MenuBarDateText.text(for: Date(),
                             format: settings.menuBarFormat,
                             custom: settings.customDateFormat)
    }

    /// The stored list is of calendars to *hide*, so the toggle is inverted.
    private func binding(for calendar: EKCalendar) -> Binding<Bool> {
        Binding(
            get: { !settings.isCalendarHidden(calendar.calendarIdentifier) },
            set: { settings.setCalendar(calendar.calendarIdentifier, hidden: !$0) })
    }

    /// Access can be granted or revoked in System Settings while this pane is
    /// open, so it is polled the same way `PermissionsPane` polls.
    private func refresh() {
        let granted = PermissionsService.shared.hasCalendarAccess
        guard granted != hasCalendarAccess || (granted && calendars.isEmpty) else { return }
        hasCalendarAccess = granted
        calendars = granted ? events.allCalendars() : []
    }
}
