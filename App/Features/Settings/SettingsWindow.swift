import SwiftUI

/// Tabbed Settings window. One tab per feature set — Clipboard & Snippets,
/// Capture, Keep Awake, Windows, Calendar, Network — while Hotkeys, Permissions and
/// About are shared across all of them.
struct SettingsView: View {
    /// Which tab is showing. Defaults to the first; the `MUKKER_OPEN_SETTINGS`
    /// debug hook opens straight onto another for screenshots.
    @State var selection: SettingsTab = .clipboard

    var body: some View {
        TabView(selection: $selection) {
            ClipboardPane()
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
                .tag(SettingsTab.clipboard)
            CapturePane()
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
                .tag(SettingsTab.capture)
            KeepAwakePane()
                .tabItem { Label("Keep Awake", systemImage: "moon.zzz") }
                .tag(SettingsTab.keepAwake)
            WindowTilingPane()
                .tabItem { Label("Windows", systemImage: "rectangle.split.2x1") }
                .tag(SettingsTab.windows)
            CalendarPane()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(SettingsTab.calendar)
            NetworkPane()
                .tabItem { Label("Network", systemImage: "network") }
                .tag(SettingsTab.network)
            HotkeysPane()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                .tag(SettingsTab.hotkeys)
            PermissionsPane()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .focusEffectDisabled()
        .frame(width: 600, height: 620)
        .padding()
    }
}

enum SettingsTab: String, CaseIterable {
    case clipboard, capture, keepAwake, windows, calendar, network, hotkeys, permissions, about
}
