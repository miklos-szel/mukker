import Combine
import Foundation

/// Periodically purges clipboard items older than the per-kind retention window.
@MainActor
final class ClipboardRetentionService {
    static let shared = ClipboardRetentionService()

    private let repository: ClipboardRepository
    private var timer: Timer?
    private var cancellable: AnyCancellable?

    init(repository: ClipboardRepository = ClipboardRepository()) {
        self.repository = repository
    }

    func start() {
        sweepNow()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Re-sweep when a retention-relevant setting changes — not on every
        // settings write (dragging the popup-size slider used to sweep too).
        // `objectWillChange` fires before the write, so the snapshot is taken
        // after delivery on the run loop, when the new value is readable.
        let settings = ClipboardSettings.shared
        var last = RetentionSnapshot(settings)
        cancellable = settings.objectWillChange
            .receive(on: RunLoop.main)
            .compactMap { _ -> Void? in
                // Delivered on the main run loop.
                let current = MainActor.assumeIsolated { RetentionSnapshot(settings) }
                guard current != last else { return nil }
                last = current
                return ()
            }
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] in self?.sweepNow() }
    }

    /// The settings a sweep depends on (plus the per-kind keep toggles).
    struct RetentionSnapshot: Equatable {
        let textRetention: RetentionPeriod
        let imageRetention: RetentionPeriod
        let fileRetention: RetentionPeriod
        let keepText: Bool
        let keepImages: Bool
        let keepFiles: Bool

        @MainActor
        init(_ settings: ClipboardSettings) {
            textRetention = settings.textRetention
            imageRetention = settings.imageRetention
            fileRetention = settings.fileRetention
            keepText = settings.keepText
            keepImages = settings.keepImages
            keepFiles = settings.keepFiles
        }
    }

    func sweepNow() {
        let settings = ClipboardSettings.shared
        let now = Date()
        var didDelete = false

        for kind in ClipKind.allCases {
            let retention = settings.retention(for: kind)
            guard let seconds = retention.seconds else { continue } // forever
            let cutoff = now.addingTimeInterval(-seconds)
            do {
                // The repository also removes the deleted rows' on-disk files.
                let removed = try repository.purgeOlderThan(kind: kind, cutoff: cutoff)
                if !removed.isEmpty { didDelete = true }
                // Archive expiring text before the rows disappear.
                ForeverHistoryArchive.archive(removed)
            } catch {
                Log.clipboard.error("Retention sweep failed for \(kind.rawValue, privacy: .public): \(error.localizedDescription)")
            }
        }

        // Refresh the in-memory cache so expired rows disappear from the popup.
        // Skipped when nothing was deleted — this sweep also runs on every
        // settings change, and most changes don't affect retention.
        if didDelete {
            ClipboardCache.shared.loadAll()
            Log.clipboard.info("Retention sweep removed expired items")
        }
    }
}
