import SwiftUI

/// Live status of every macOS privacy permission the app relies on, plus the
/// login item. `PermissionsService` reads status on demand (not `@Published`)
/// and the user changes it outside the app in System Settings, so status is
/// mirrored into local state and refreshed on a timer while this pane is visible.
struct PermissionsPane: View {
    @State private var accessibility = false
    @State private var screenRecording = false
    @State private var launchAtLogin = false

    private let pollTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    granted: accessibility,
                    open: { PermissionsService.shared.openAccessibilitySettings(); refresh() },
                    request: { PermissionsService.shared.requestAccessibilityPermission(); refresh() })
            } header: {
                Text("Accessibility")
            } footer: {
                Text("Needed to paste into the active app (⌘V), to merge with double-⌘C, "
                     + "and to auto-scroll the target during scrolling capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                PermissionRow(
                    granted: screenRecording,
                    open: { PermissionsService.shared.openScreenRecordingSettings(); refresh() },
                    request: { PermissionsService.shared.requestScreenRecordingPermission(); refresh() })
            } header: {
                Text("Screen Recording")
            } footer: {
                Text("Required to capture your screen. Without it, captures fail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch \(Branding.name) at login", isOn: launchAtLoginBinding)
            } header: {
                Text("Start at Login")
            } footer: {
                Text("The system is the source of truth — this can also be changed in "
                     + "System Settings → General → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(pollTimer) { _ in refresh() }
    }

    private func refresh() {
        accessibility = PermissionsService.shared.hasAccessibilityPermission
        screenRecording = PermissionsService.shared.hasScreenRecordingPermission
        launchAtLogin = LoginItemService.shared.isEnabled
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                LoginItemService.shared.setEnabled(newValue)
                // Re-read so a failed registration reverts the toggle visually.
                launchAtLogin = LoginItemService.shared.isEnabled
            }
        )
    }
}

/// A single permission's status dot + label and grant buttons.
private struct PermissionRow: View {
    let granted: Bool
    let open: () -> Void
    let request: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button("Open System Settings", action: open)
                if !granted {
                    Button("Request Access", action: request)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(granted ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(granted ? "Granted" : "Not granted")
            }
        }
    }
}
