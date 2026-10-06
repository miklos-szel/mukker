import SwiftUI

/// The bandwidth monitor: the live rate beside the date, and which periods the
/// menu's Network submenu totals per interface.
struct NetworkPane: View {
    @ObservedObject private var settings = BandwidthSettings.shared
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable bandwidth monitor", isOn: $settings.isEnabled)
                Toggle("Show current speed in the menu bar", isOn: $settings.showsInMenuBar)
                    .disabled(!settings.isEnabled)
                MenuBarSizeSlider()
                    .disabled(!settings.isEnabled || !settings.showsInMenuBar)
                Picker("Refresh every", selection: $settings.refreshInterval) {
                    ForEach(BandwidthSettings.refreshIntervals, id: \.self) { seconds in
                        Text(seconds == 1 ? "1 second" : "\(seconds) seconds").tag(seconds)
                    }
                }
                .disabled(!settings.isEnabled)
            } header: {
                Text("Bandwidth")
            } footer: {
                Text("Shows the download (↓) and upload (↑) rate across all network "
                     + "interfaces to the left of the date, averaged over the refresh interval. VPN tunnels are "
                     + "not counted separately — their traffic already crosses a physical "
                     + "interface.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(BandwidthPeriod.allCases) { period in
                    Toggle(period.label, isOn: Binding(
                        get: { settings.shows(period) },
                        set: { settings.setShows(period, $0) }))
                }
            } header: {
                Text("Network Menu")
            } footer: {
                Text("Data transferred per interface, listed in the menu's Network submenu. "
                     + "Only traffic while \(Branding.name) is running is counted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.isEnabled)

            Section {
                Button("Reset Statistics…") { confirmingReset = true }
                    .confirmationDialog("Reset all network statistics?",
                                        isPresented: $confirmingReset) {
                        Button("Reset", role: .destructive) {
                            BandwidthService.shared.resetStatistics()
                        }
                    } message: {
                        Text("The recorded totals for every interface are deleted. This can't be undone.")
                    }
            }
        }
        .formStyle(.grouped)
    }
}
