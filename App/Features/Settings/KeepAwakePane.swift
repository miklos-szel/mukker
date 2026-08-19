import SwiftUI

/// The Keep Awake side of the app: the live on/off control plus how long an
/// activation lasts and what turns it off again. The current state lives on
/// `KeepAwakeService` (which owns the power assertion); everything below it is
/// `KeepAwakeSettings`.
///
/// The service publishes only on/off — the remaining time is derived from its
/// deadline — so the countdown is polled once a second while this pane is
/// visible, the same shape `PermissionsPane` uses for permission status.
struct KeepAwakePane: View {
    @ObservedObject private var service = KeepAwakeService.shared
    @ObservedObject private var settings = KeepAwakeSettings.shared
    @State private var status = ""

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button(service.isActive ? "Turn Off" : "Turn On") {
                        service.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(service.isActive ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 10, height: 10)
                        Text(status).monospacedDigit()
                    }
                }
            } header: {
                Text("Status")
            } footer: {
                Text("Turning it on from here or from the menu bar uses the default "
                     + "duration below. The menu bar can also start a one-off duration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Picker("Default duration", selection: $settings.defaultDuration) {
                    ForEach(KeepAwakeDuration.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                Toggle("Turn on when \(Branding.name) launches", isOn: $settings.activateAtLaunch)
                Toggle("Turn off when the Mac is put to sleep manually",
                       isOn: $settings.deactivateOnManualSleep)
            }

            Section {
                Toggle("Allow the display to sleep", isOn: $settings.allowDisplaySleep)
            } footer: {
                Text("Keeps the Mac running for a long job while letting the screen "
                     + "switch off. Off by default, so the display stays awake too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { status = service.statusText }
        .onReceive(tick) { _ in status = service.statusText }
    }
}
