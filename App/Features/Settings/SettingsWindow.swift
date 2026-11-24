import SwiftUI

/// Tabbed Settings window. One tab per feature set — Clipboard & Snippets,
/// Capture, Keep Awake, Windows, Calendar, Network, Mouse, Translate, Dictation — while Hotkeys, Permissions and
/// About are shared across all of them.
struct SettingsView: View {
    /// Which tab is showing. Defaults to the first; the `MUKKER_OPEN_SETTINGS`
    /// debug hook opens straight onto another for screenshots.
    @State private var selection: SettingsTab
    /// New per construction, so a root swapped in by `openSettings(tab:)`
    /// re-seeds `selection` instead of keeping the old view's state.
    private let identity = UUID()

    init(selection: SettingsTab = .clipboard) {
        _selection = State(initialValue: selection)
    }

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
            MousePane()
                .tabItem { Label("Mouse", systemImage: "computermouse") }
                .tag(SettingsTab.mouse)
            TranslatePane()
                .tabItem { Label("Translate", systemImage: "character.bubble") }
                .tag(SettingsTab.translate)
            DictationPane()
                .tabItem { Label("Dictation", systemImage: "mic") }
                .tag(SettingsTab.dictation)
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
        .id(identity)
        // Twelve tab labels need ~780 pt in a row (eleven needed ~710 pt);
        // narrower and AppKit drops the last tabs into overflow.
        .frame(width: 820, height: 640)
        .padding()
    }
}

enum SettingsTab: String, CaseIterable {
    case clipboard, capture, keepAwake, windows, calendar, network, mouse, translate, dictation, hotkeys, permissions, about
}
