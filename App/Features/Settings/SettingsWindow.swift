import SwiftUI

/// Tabbed Settings window. The two feature-specific tabs mirror the apps this
/// one was merged from — Clipboard & Snippets, and Capture — while Hotkeys,
/// Permissions and About are shared across both.
struct SettingsView: View {
    var body: some View {
        TabView {
            ClipboardPane()
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            CapturePane()
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
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
