import Foundation

/// Writes text clipboard items to a "forever history" directory just before they
/// are deleted (retention expiry or the max-items trim), so they're never lost.
/// No-op unless enabled.
enum ForeverHistoryArchive {
    /// Convenience that reads the live settings.
    @MainActor
    static func archive(_ items: [ClipItem]) {
        let s = ClipboardSettings.shared
        archive(items, enabled: s.foreverHistoryEnabled, directory: s.foreverHistoryDirectory)
    }

    /// Pure core (testable): archives `.text` items with content to `directory`.
    static func archive(_ items: [ClipItem], enabled: Bool, directory: String) {
        guard enabled else { return }

        let textItems = items.filter { $0.kind == .text && !($0.textContent ?? "").isEmpty }
        guard !textItems.isEmpty else { return }

        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.clipboard.error("Forever-history: cannot create \(dir.path, privacy: .public): \(error.localizedDescription)")
            return
        }

        for item in textItems {
            guard let text = item.textContent else { continue }
            let stamp = filenameFormatter.string(from: item.createdAt)
            let hash8 = String(item.contentHash.prefix(8))
            let url = dir.appendingPathComponent("\(stamp)_\(hash8).txt")
            // Dedupe: same content (hash) at the same second is already archived.
            guard !fm.fileExists(atPath: url.path) else { continue }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Log.clipboard.error("Forever-history: failed to write \(url.lastPathComponent, privacy: .public): \(error.localizedDescription)")
            }
        }
    }

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
