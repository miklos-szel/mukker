import AppKit
import CryptoKit
import Foundation

/// Polls NSPasteboard for changes and persists new text/image items.
final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    private let repository: ClipboardRepository
    private let pollInterval: TimeInterval = 0.2
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    init(repository: ClipboardRepository = ClipboardRepository()) {
        self.repository = repository
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.clipboard.info("Clipboard monitor started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Lets the fast-append service suppress one capture cycle after it
    /// writes a merged result back to the pasteboard.
    func suppressNextChange() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private func tick() {
        // The timer fires on RunLoop.main, so we're on the main thread.
        MainActor.assumeIsolated {
            tickOnMain()
        }
    }

    @MainActor
    private func tickOnMain() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        let sourceApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let settings = ClipboardSettings.shared

        // Skip capture entirely for ignored apps (e.g. password managers).
        if let app = sourceApp, settings.ignoredBundleIDs.contains(app) {
            Log.clipboard.debug("Skipping clipboard from ignored app \(app, privacy: .public)")
            return
        }

        let types = pb.types ?? []

        if settings.ignoreConcealedItems, isSensitiveCopy(pb, types: types) {
            Log.clipboard.debug("Skipping sensitive clipboard item")
            return
        }

        // File lists first, then images, then strings.
        if types.contains(.fileURL), settings.keepFiles {
            captureFiles(pb: pb, sourceApp: sourceApp)
            return
        }
        if (types.contains(.png) || types.contains(.tiff)), settings.keepImages {
            captureImage(pb: pb, sourceApp: sourceApp)
            return
        }
        if types.contains(.string), settings.keepText,
           let str = pb.string(forType: .string),
           !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            captureText(str, sourceApp: sourceApp, rtfData: richTextData(from: pb))
        }
    }

    /// Whether the current pasteboard should be treated as sensitive and skipped.
    ///
    /// Two signals, neither of which fires for ordinary copies:
    ///  - `org.nspasteboard.ConcealedType`/`TransientType`: the de-facto convention
    ///    desktop password managers (the 1Password app, etc.) use to opt out of history.
    ///  - A Chromium `org.chromium.source-url` pointing at a known password-manager
    ///    browser-extension popup. Those extensions copy through the browser's normal
    ///    clipboard (no concealed marker) and the frontmost app is the browser, so the
    ///    source URL is the only reliable signal that the copy came from the manager.
    @MainActor
    private func isSensitiveCopy(_ pb: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        if types.contains(concealed) || types.contains(transient) { return true }

        let sourceURLType = NSPasteboard.PasteboardType("org.chromium.source-url")
        if let data = pb.data(forType: sourceURLType),
           let url = String(data: data, encoding: .utf8),
           let id = Self.chromeExtensionID(from: url),
           ClipboardSettings.shared.passwordManagerExtensionIDs.contains(id) {
            return true
        }
        return false
    }

    /// Extension ID from a `chrome-extension://<id>/…` URL, else nil.
    private static func chromeExtensionID(from url: String) -> String? {
        let prefix = "chrome-extension://"
        guard url.hasPrefix(prefix) else { return nil }
        let id = url.dropFirst(prefix.count).prefix { $0 != "/" }
        return id.isEmpty ? nil : String(id)
    }

    /// RTF representation of the current pasteboard text, if the source provided
    /// formatting (native RTF, else converted from HTML). nil for plain copies.
    private func richTextData(from pb: NSPasteboard) -> Data? {
        if let rtf = pb.data(forType: .rtf) { return rtf }
        if let html = pb.data(forType: .html),
           let attr = try? NSAttributedString(
                data: html,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil) {
            return try? attr.data(from: NSRange(location: 0, length: attr.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }
        return nil
    }

    @MainActor
    private func captureText(_ text: String, sourceApp: String?, rtfData: Data?) {
        // Ignore text over the configured size limit to avoid history bloat.
        if let limit = ClipboardSettings.shared.maxClipSize.characterLimit,
           text.count > limit {
            Log.clipboard.debug("Skipping clipboard text over max size (\(text.count, privacy: .public) > \(limit, privacy: .public))")
            return
        }
        let hash = sha256(text)
        let preview = String(text.prefix(200))
        // Persist formatting (if any) to disk, named by the same plain-text hash.
        var richPath: String?
        if let rtfData {
            let url = AppPaths.richTextDirectory.appendingPathComponent("\(hash).rtf")
            if !FileManager.default.fileExists(atPath: url.path) {
                try? rtfData.write(to: url)
            }
            richPath = url.path
        }
        let item = ClipItem(
            id: nil,
            kind: .text,
            textContent: text,
            imagePath: nil,
            imageWidth: nil,
            imageHeight: nil,
            previewText: preview,
            sourceApp: sourceApp,
            createdAt: Date(),
            pinned: false,
            contentHash: hash,
            lastUsedAt: nil,
            richTextPath: richPath
        )
        persist(item, label: "text")
    }

    @MainActor
    private func captureImage(pb: NSPasteboard, sourceApp: String?) {
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let image = NSImage(data: data) else {
            return
        }
        // Re-encode to PNG for consistent storage
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else { return }
        let hash = sha256(data: pngData)
        let filename = "\(hash).png"
        let url = AppPaths.imagesDirectory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try pngData.write(to: url)
            } catch {
                Log.clipboard.error("Failed to write image to disk: \(error.localizedDescription)")
                return
            }
        }
        // Pixel dimensions from the bitmap rep — image.size is in points and
        // under-reports retina screenshots by the backing scale factor.
        let item = ClipItem(
            id: nil,
            kind: .image,
            textContent: nil,
            imagePath: url.path,
            imageWidth: rep.pixelsWide,
            imageHeight: rep.pixelsHigh,
            previewText: "Image \(rep.pixelsWide)×\(rep.pixelsHigh)",
            sourceApp: sourceApp,
            createdAt: Date(),
            pinned: false,
            contentHash: hash,
            lastUsedAt: nil
        )
        persist(item, label: "image")
    }

    @MainActor
    private func captureFiles(pb: NSPasteboard, sourceApp: String?) {
        guard let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty else { return }
        let paths = urls.map(\.path)
        let joined = paths.joined(separator: "\n")
        let hash = sha256(joined)
        let firstName = urls.first?.lastPathComponent ?? ""
        let preview = urls.count == 1
            ? firstName
            : "\(urls.count) files: \(firstName), …"
        let item = ClipItem(
            id: nil,
            kind: .file,
            textContent: joined,
            imagePath: nil,
            imageWidth: nil,
            imageHeight: nil,
            previewText: preview,
            sourceApp: sourceApp,
            createdAt: Date(),
            pinned: false,
            contentHash: hash,
            lastUsedAt: nil
        )
        persist(item, label: "file")
    }

    @MainActor
    private func persist(_ item: ClipItem, label: String) {
        do {
            if let inserted = try repository.insertIfNew(item) {
                Log.clipboard.info("Captured \(label, privacy: .public) item id=\(inserted.id ?? -1)")
                ClipboardCache.shared.insertNew(inserted)
                let trimmed = try repository.trim(to: ClipboardSettings.shared.maxHistoryItems)
                ForeverHistoryArchive.archive(trimmed)
            } else if ClipboardSettings.shared.moveToTopOnUse,
                      let existing = try repository.fetchOne(contentHash: item.contentHash),
                      let id = existing.id {
                // Re-copy of content already in history: bump it to the top
                // instead of silently dropping the capture.
                try repository.bumpLastUsed(id: id)
                if let refreshed = try repository.fetchOne(id: id) {
                    ClipboardCache.shared.upsert(refreshed)
                }
                Log.clipboard.debug("Bumped duplicate \(label, privacy: .public) item id=\(id)")
            }
        } catch {
            Log.clipboard.error("Failed to save \(label, privacy: .public) item: \(error.localizedDescription)")
        }
    }

    private func sha256(_ text: String) -> String {
        sha256(data: Data(text.utf8))
    }

    private func sha256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
