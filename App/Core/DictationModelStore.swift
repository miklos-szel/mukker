import CryptoKit
import Foundation

/// Downloads, verifies and deletes the Dictation model files under
/// `AppPaths.modelsDirectory`. A file only lands under its final name after
/// its SHA-256 matched, so "the file exists" means "the file is good".
@MainActor
final class DictationModelStore: ObservableObject {
    static let shared = DictationModelStore()

    enum Phase: Equatable {
        case idle
        /// 0…1 over every file the model still needs.
        case downloading(Double)
        case verifying
        case failed(String)
    }

    /// Per model id; absent means idle.
    @Published private(set) var phases: [String: Phase] = [:]
    /// Bumped whenever a file appears or disappears, so views re-read
    /// `isInstalled` without the store caching the filesystem.
    @Published private(set) var revision = 0

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]
    private let session = URLSession(configuration: .default)

    nonisolated static func url(for file: DictationModelFile) -> URL {
        AppPaths.modelsDirectory.appendingPathComponent(file.fileName)
    }

    nonisolated static func isPresent(_ file: DictationModelFile) -> Bool {
        FileManager.default.fileExists(atPath: url(for: file).path)
    }

    func isInstalled(_ model: DictationModel) -> Bool {
        _ = revision
        return DictationCatalog.files(for: model).allSatisfy(Self.isPresent)
    }

    func phase(for model: DictationModel) -> Phase { phases[model.id] ?? .idle }

    var isBusy: Bool { phases.values.contains { if case .downloading = $0 { return true }; return $0 == .verifying } }

    /// Bytes still to fetch for `model` (the detector is shared, so it only
    /// counts while missing).
    func remainingBytes(for model: DictationModel) -> Int64 {
        DictationCatalog.files(for: model).filter { !Self.isPresent($0) }.reduce(0) { $0 + $1.byteSize }
    }

    // MARK: - Download

    func download(_ model: DictationModel) {
        guard tasks[model.id] == nil else { return }
        let missing = DictationCatalog.files(for: model).filter { !Self.isPresent($0) }
        guard !missing.isEmpty else { return }
        let total = missing.reduce(0) { $0 + $1.byteSize }
        Log.dictation.info("downloading \(model.id, privacy: .public): \(missing.count) file(s), \(total) bytes")
        phases[model.id] = .downloading(0)
        fetch(missing, for: model, done: 0, total: total)
    }

    func cancel(_ model: DictationModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        observations[model.id] = nil
        phases[model.id] = nil
    }

    /// Removes the model's own file. The language detector is shared, so it
    /// goes only when no other installed model needs it.
    func delete(_ model: DictationModel) {
        cancel(model)
        var doomed = [model.file]
        let othersNeedDetector = DictationCatalog.models.contains {
            $0.id != model.id && $0.needsLanguageDetector && Self.isPresent($0.file)
        }
        if model.needsLanguageDetector && !othersNeedDetector { doomed.append(DictationCatalog.languageDetector) }
        for file in doomed { try? FileManager.default.removeItem(at: Self.url(for: file)) }
        TranscriptionEngine.shared.unload()
        revision += 1
        Log.dictation.info("deleted \(model.id, privacy: .public)")
    }

    private func fetch(_ files: [DictationModelFile], for model: DictationModel, done: Int64, total: Int64) {
        guard let file = files.first else {
            tasks[model.id] = nil
            observations[model.id] = nil
            phases[model.id] = nil
            revision += 1
            Log.dictation.info("\(model.id, privacy: .public) ready")
            return
        }
        let task = session.downloadTask(with: file.downloadURL) { [weak self] temp, response, error in
            // The temporary file is deleted when this handler returns, so move
            // it aside synchronously before hopping anywhere.
            var staged: URL?
            if let temp, error == nil {
                let target = AppPaths.modelsDirectory.appendingPathComponent(file.fileName + ".partial")
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.moveItem(at: temp, to: target)) != nil { staged = target }
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let failure: String? = {
                if let error = error as? URLError, error.code == .cancelled { return "" }
                if let error { return error.localizedDescription }
                if !(200..<300).contains(status) { return "The server answered \(status)." }
                if staged == nil { return "The download couldn't be saved." }
                return nil
            }()
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    self?.finished(file, staged: staged, failure: failure, remaining: Array(files.dropFirst()),
                                   for: model, done: done + file.byteSize, total: total)
                }
            }
        }
        observations[model.id] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = (Double(done) + progress.fractionCompleted * Double(file.byteSize)) / Double(max(total, 1))
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    guard let self, case .downloading = self.phases[model.id] else { return }
                    self.phases[model.id] = .downloading(min(fraction, 1))
                }
            }
        }
        tasks[model.id] = task
        task.resume()
    }

    private func finished(_ file: DictationModelFile, staged: URL?, failure: String?,
                          remaining: [DictationModelFile], for model: DictationModel, done: Int64, total: Int64) {
        guard tasks[model.id] != nil else {
            // Cancelled meanwhile.
            if let staged { try? FileManager.default.removeItem(at: staged) }
            return
        }
        if let failure {
            if let staged { try? FileManager.default.removeItem(at: staged) }
            tasks[model.id] = nil
            observations[model.id] = nil
            phases[model.id] = failure.isEmpty ? nil : .failed(failure)
            Log.dictation.error("download of \(file.fileName, privacy: .public) failed: \(failure, privacy: .public)")
            return
        }
        guard let staged else { return }
        phases[model.id] = .verifying
        let expected = file.sha256
        DispatchQueue.global(qos: .utility).async {
            let actual = Self.sha256(of: staged)
            var moveError: String?
            if actual == expected {
                let final = Self.url(for: file)
                try? FileManager.default.removeItem(at: final)
                do {
                    try FileManager.default.moveItem(at: staged, to: final)
                    try? FileManager.default.setAttributes([.posixPermissions: AppPaths.privateFilePermissions],
                                                           ofItemAtPath: final.path)
                } catch {
                    moveError = error.localizedDescription
                }
            } else {
                try? FileManager.default.removeItem(at: staged)
            }
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    guard self.tasks[model.id] != nil else { return }
                    if actual != expected || moveError != nil {
                        self.tasks[model.id] = nil
                        self.observations[model.id] = nil
                        self.phases[model.id] = .failed(moveError ?? "The downloaded file didn't match its checksum.")
                        Log.dictation.error("\(file.fileName, privacy: .public) failed verification")
                        return
                    }
                    self.phases[model.id] = .downloading(Double(done) / Double(max(total, 1)))
                    self.fetch(remaining, for: model, done: done, total: total)
                }
            }
        }
    }

    /// Streams the file through SHA-256 in 4 MB chunks (the files are up to ~900 MB).
    nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { try? handle.read(upToCount: 4 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
