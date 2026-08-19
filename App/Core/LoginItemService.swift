import ServiceManagement

/// Wraps the modern `SMAppService.mainApp` login-item API (macOS 13+). The
/// system is the source of truth for the enabled state — the user can also
/// toggle it from System Settings → General → Login Items — so we read status
/// live rather than mirroring it into UserDefaults.
@MainActor
final class LoginItemService {
    static let shared = LoginItemService()

    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers/unregisters the app as a login item.
    /// Returns true on success; logs and returns false on failure.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else       { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            Log.app.error("Login item toggle failed: \(error.localizedDescription)")
            return false
        }
    }
}
