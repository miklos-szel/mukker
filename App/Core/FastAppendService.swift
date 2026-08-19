import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation

/// Detects a double-tap of ⌘C and appends the freshly-copied text onto the
/// previously-captured text item (the "Fast append selected text" feature).
@MainActor
final class FastAppendService {
    static let shared = FastAppendService()

    private let repository: ClipboardRepository
    private var monitor: Any?
    private var lastCmdCAt: TimeInterval = 0
    private let doubleTapWindow: TimeInterval = 0.5

    init(repository: ClipboardRepository = ClipboardRepository()) {
        self.repository = repository
    }

    func start() {
        guard monitor == nil else { return }
        // Global key-down monitor — observes ⌘C in other apps. Requires the
        // Accessibility permission we already need for pasting.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: NSEvent) {
        guard ClipboardSettings.shared.fastAppendEnabled else { return }
        guard event.modifierFlags.contains(.command) else { return }
        guard event.keyCode == UInt16(kVK_ANSI_C) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCmdCAt < doubleTapWindow {
            lastCmdCAt = 0
            // Let the OS finish the second copy before we read the pasteboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.performAppend()
            }
        } else {
            lastCmdCAt = now
        }
    }

    private func performAppend() {
        let settings = ClipboardSettings.shared
        let pb = NSPasteboard.general
        guard let current = pb.string(forType: .string), !current.isEmpty else { return }

        // The most-recent text item is the just-copied `current`. We append it
        // onto the one before it (the "previously copied" text).
        let textItems = ClipboardCache.shared.items.filter { $0.kind == .text }
        guard textItems.count >= 2 else { return }
        let target = textItems[1]
        guard let targetId = target.id else { return }

        let previousText = ClipboardCache.shared.fullText(for: target) ?? (target.textContent ?? "")
        let merged = Self.merge(previous: previousText, current: current, separator: settings.appendSeparator)
        let newHash = sha256(merged)

        do {
            try repository.updateTextContent(id: targetId, newContent: merged, newHash: newHash)
            if let refreshed = try repository.fetchOne(id: targetId) {
                ClipboardCache.shared.update(refreshed)
            }
        } catch {
            Log.clipboard.error("Fast append failed: \(error.localizedDescription)")
            return
        }

        if settings.fastAppendBackToPasteboard {
            pb.clearContents()
            pb.setString(merged, forType: .string)
            // Don't let the monitor capture our own write as a new item.
            ClipboardMonitor.shared.suppressNextChange()
        }

        if settings.playAppendSound {
            NSSound(named: NSSound.Name("Purr"))?.play()
        }
        Log.clipboard.info("Fast-appended onto item id=\(targetId)")
    }

    /// Pure merge of previously-copied text + just-copied text with a separator.
    /// Extracted for testability.
    nonisolated static func merge(previous: String, current: String, separator: AppendSeparator) -> String {
        previous + separator.literal + current
    }

    private func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
