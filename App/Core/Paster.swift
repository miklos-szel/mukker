import AppKit
import Carbon.HIToolbox
import Foundation

/// Writes an item to the system pasteboard and simulates Cmd+V into the previously active app.
final class Paster {
    static let shared = Paster()

    /// Paste a clip item. Falls back to copy-only if Accessibility is not trusted.
    @MainActor
    func paste(_ item: ClipItem, autoPaste: Bool = true) {
        writeToPasteboard(item)
        moveToTopIfNeeded(item)
        guard autoPaste else { return }
        guard PermissionsService.shared.hasAccessibilityPermission else {
            Log.paste.notice("Skipping auto-paste; accessibility not trusted")
            return
        }
        ActiveAppTracker.shared.reactivate()
        // Give the app a moment to come forward before sending keystrokes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.sendCommandV()
        }
    }

    /// Bumps the item to the top of history when the corresponding setting is on.
    @MainActor
    private func moveToTopIfNeeded(_ item: ClipItem) {
        guard ClipboardSettings.shared.moveToTopOnUse, let id = item.id else { return }
        try? ClipboardRepository().bumpLastUsed(id: id)
        ClipboardCache.shared.bumpLastUsed(id: id)
    }

    /// Paste a snippet content as text.
    @MainActor
    func pasteText(_ text: String, autoPaste: Bool = true) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard autoPaste else { return }
        guard PermissionsService.shared.hasAccessibilityPermission else { return }
        ActiveAppTracker.shared.reactivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.sendCommandV()
        }
    }

    private func writeToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            // Rich items write RTF (for formatting-aware apps) plus a plain fallback.
            if let rtfPath = item.richTextPath,
               let rtf = try? Data(contentsOf: URL(fileURLWithPath: rtfPath)) {
                pb.setData(rtf, forType: .rtf)
            }
            if let txt = item.textContent {
                pb.setString(txt, forType: .string)
            }
        case .image:
            if let path = item.imagePath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                pb.setData(data, forType: .png)
                if let image = NSImage(data: data),
                   let tiff = image.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
            }
        case .file:
            if let joined = item.textContent {
                let urls = joined
                    .split(separator: "\n")
                    .map { URL(fileURLWithPath: String($0)) as NSURL }
                if !urls.isEmpty {
                    pb.writeObjects(urls)
                }
            }
        }
    }

    private func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_V)

        guard let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let vDown = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Command), keyDown: false)
        else {
            Log.paste.error("Failed to create CGEvents for paste")
            return
        }
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        let tap: CGEventTapLocation = .cghidEventTap
        cmdDown.post(tap: tap)
        vDown.post(tap: tap)
        vUp.post(tap: tap)
        cmdUp.post(tap: tap)
    }
}
