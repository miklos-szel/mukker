import SwiftUI

/// The Razer mouse battery readout: on/off, plus the live reading.
struct MousePane: View {
    @ObservedObject private var settings = MouseBatterySettings.shared
    @ObservedObject private var service = MouseBatteryService.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show Razer mouse battery", isOn: $settings.isEnabled)
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        if let percent = service.reading?.percent {
                            Circle()
                                .fill(Color(nsColor: MouseBatteryService.color(for: percent)))
                                .frame(width: 10, height: 10)
                        }
                        Text(statusText).monospacedDigit()
                        Button("Refresh") { service.refresh() }
                            .disabled(!settings.isEnabled)
                    }
                }
            } header: {
                Text("Mouse battery")
            } footer: {
                Text("Adds a Mouse submenu showing the battery level while a supported Razer mouse "
                     + "(or its wireless receiver) is plugged in, and a warning at the top of the menu "
                     + "below \(MouseBatterySettings.lowThreshold)%. Read over USB every five minutes "
                     + "and whenever the menu opens; needs no permissions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Supported mice") {
                ForEach(Array(Set(RazerBattery.supportedModels.map(\.name))).sorted(), id: \.self) {
                    Text($0)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { service.refresh() }
    }

    private var statusText: String {
        guard settings.isEnabled else { return "Off" }
        guard let reading = service.reading else { return "No supported Razer mouse connected" }
        guard let percent = reading.percent else { return "\(reading.modelName) — asleep or off" }
        return "\(reading.modelName) — \(percent)%" + (reading.isCharging ? ", charging" : "")
    }
}
