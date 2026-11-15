import AppKit
import Carbon.HIToolbox
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
        // Same rules as ordinary capture: text history on, not from an ignored
        // app, not a concealed/password-manager copy.
        guard settings.keepText else { return }
        let pb = NSPasteboard.general
        let sourceApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard ClipboardMonitor.shared.shouldRecord(pb, sourceApp: sourceApp, settings: settings) else { return }
        guard let current = pb.string(forType: .string), !current.isEmpty else { return }

        // The most-recent text item should be the just-copied `current`; we append
        // it onto the one before it (the "previously copied" text). Ordered by
        // recency alone — the cache sorts pinned items first, which would make an
        // old pinned item look like "the latest copy".
        let textItems = ClipboardCache.shared.items
            .filter { $0.kind == .text }
            .sorted { $0.effectiveTimestamp > $1.effectiveTimestamp }
        guard textItems.count >= 2 else { return }
        // If the monitor hasn't recorded this copy (not polled yet, over the size
        // limit, …) the items are not what we think they are — merging would glue
        // the copy onto an unrelated entry.
        guard textItems[0].contentHash == ContentHash.sha256Hex(current) else {
            Log.clipboard.debug("Fast append skipped: latest history item is not the copied text")
            return
        }
        let target = textItems[1]
        guard let targetId = target.id else { return }

        let previousText = ClipboardCache.shared.fullText(for: target) ?? (target.textContent ?? "")
        let merged = Self.merge(previous: previousText, current: current, separator: settings.appendSeparator)
        let newHash = ContentHash.sha256Hex(merged)

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
}
