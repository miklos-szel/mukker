import AppKit
import HotKey
import SwiftUI

/// Single menu-bar entry point for both feature sets. Each original app's
/// functions sit behind its own submenu; only the shared items (Settings, Quit)
/// live at the top level. Shortcut glyphs are derived from `ShortcutSettings`,
/// the same object the global hotkeys and the Hotkeys settings tab use, so the
/// menu can never advertise a stale shortcut.
@main
struct AppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @ObservedObject private var captureSettings = CaptureSettings.shared
    @ObservedObject private var keepAwake = KeepAwakeService.shared

    var body: some Scene {
        // The icon carries the Keep Awake state, so the menu bar shows at a
        // glance whether the Mac is being held awake.
        MenuBarExtra(Branding.name,
                     image: keepAwake.isActive ? "MenuBarIconAwake" : "MenuBarIcon") {
            Menu("Clipboard & Snippets") {
                menuItem("Show Clipboard & Snippets", combo: shortcuts.popupCombo) {
                    appDelegate.showPopup()
                }
                Divider()
                Button("Snippets Manager…") {
                    appDelegate.openSnippetsManager()
                }
            }

            Menu("Capture") {
                menuItem("Capture Area", combo: shortcuts.areaCombo) {
                    appDelegate.captureArea()
                }
                menuItem("Capture Screen", combo: shortcuts.fullscreenCombo) {
                    appDelegate.captureScreen()
                }
                menuItem("Scrolling Capture", combo: shortcuts.scrollCombo) {
                    appDelegate.captureScrolling()
                }
#if DEBUG
                if captureSettings.enableDebugMenu {
                    Divider()
                    Button("Open Sample Editor (debug)") {
                        appDelegate.openDebugSample()
                    }
                }
#endif
            }

            Menu("Keep Awake") {
                Button(keepAwake.isActive ? "Turn Off" : "Turn On") {
                    keepAwake.toggle()
                }
                if keepAwake.isActive {
                    Text(keepAwake.statusText)
                }
                Divider()
                ForEach(KeepAwakeDuration.allCases) { duration in
                    Button(duration.label) { keepAwake.activate(for: duration) }
                }
            }

            Divider()

            Button("Settings…") {
                appDelegate.openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])

            Divider()

            Button("Quit \(Branding.name)") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }

    /// A menu item whose displayed shortcut matches `combo` from settings.
    @ViewBuilder
    private func menuItem(_ title: String, combo: KeyCombo,
                          action: @escaping () -> Void) -> some View {
        if let key = combo.swiftUIKeyEquivalent {
            Button(title, action: action)
                .keyboardShortcut(key, modifiers: combo.swiftUIModifiers)
        } else {
            Button(title, action: action)
        }
    }
}
