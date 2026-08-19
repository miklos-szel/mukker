import SwiftUI

/// Tabbed Settings window. One tab per feature set — Clipboard & Snippets,
/// Capture, Keep Awake — while Hotkeys, Permissions and About are shared
/// across all of them.
struct SettingsView: View {
    var body: some View {
        TabView {
            ClipboardPane()
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            CapturePane()
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
            KeepAwakePane()
                .tabItem { Label("Keep Awake", systemImage: "moon.zzz") }
            HotkeysPane()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            PermissionsPane()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .focusEffectDisabled()
        .frame(width: 600, height: 620)
        .padding()
    }
}
