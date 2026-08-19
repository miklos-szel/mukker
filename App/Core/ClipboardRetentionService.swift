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

        // Re-sweep when retention settings change.
        cancellable = ClipboardSettings.shared.objectWillChange
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] in self?.sweepNow() }
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
