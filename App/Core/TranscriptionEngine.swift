import Foundation
import TranscribeCpp

/// The only importer of `TranscribeCpp`: loads a model, keeps it warm, runs it
/// and unloads it after the configured idle delay.
///
/// Everything native happens on one serial queue (a `Session` is
/// single-threaded); results come back through
/// `RunLoop.main.perform(inModes: [.common])`, like the rest of the app's
/// background work, so an open menu doesn't hold them up. Never logs the
/// transcript — only lengths, timings and the language.
@MainActor
final class TranscriptionEngine {
    static let shared = TranscriptionEngine()

    struct Result {
        let text: String
        let language: String?
    }

    enum EngineError: LocalizedError {
        case modelMissing(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .modelMissing(let name): return "\(name) isn't downloaded yet."
            case .failed(let message): return message
            }
        }
    }

    private let queue = DispatchQueue(label: "\(Branding.bundleID).transcription", qos: .userInitiated)
    /// Touched only on `queue`.
    private let loaded = Loaded()
    private var unloadTimer: Timer?

    private init() {
        Transcribe.setLogHandler { level, message in
            // The library logs its own progress at info; keep only what
            // explains a failure. Its messages carry paths, never audio text.
            if level == .warn || level == .error {
                Log.dictation.error("transcribe.cpp: \(message, privacy: .public)")
            }
        }
    }

    /// Loads `model` in the background if it isn't already, so the load
    /// overlaps with the user speaking.
    func prewarm(_ model: DictationModel) {
        unloadTimer?.invalidate()
        guard DictationModelStore.shared.isInstalled(model) else { return }
        let loaded = self.loaded
        queue.async { _ = try? loaded.ensure(model) }
    }

    func transcribe(_ samples: [Float], model: DictationModel, plan: DictationLanguagePlan,
                    completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        unloadTimer?.invalidate()
        guard DictationModelStore.shared.isInstalled(model) else {
            completion(.failure(EngineError.modelMissing(model.name)))
            return
        }
        let loaded = self.loaded
        queue.async {
            let outcome = Swift.Result { try loaded.run(samples, model: model, plan: plan) }
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    self.scheduleUnload()
                    completion(outcome)
                }
            }
        }
    }

    /// Drops the loaded model (a deleted file, a switched model, the idle delay).
    func unload() {
        unloadTimer?.invalidate()
        let loaded = self.loaded
        queue.async { loaded.unload() }
    }

    private func scheduleUnload() {
        let delay = DictationSettings.shared.unloadDelay
        switch delay {
        case .never: return
        case .immediately: unload()
        default:
            let timer = Timer(timeInterval: TimeInterval(delay.rawValue), repeats: false) { _ in
                MainActor.assumeIsolated { TranscriptionEngine.shared.unload() }
            }
            RunLoop.main.add(timer, forMode: .common)
            unloadTimer = timer
        }
    }
}

/// The native objects, confined to the engine's queue.
private final class Loaded: @unchecked Sendable {
    private var modelID: String?
    private var session: Session?
    private var detector: LangIdSession?

    func ensure(_ model: DictationModel) throws -> Session {
        if modelID == model.id, let session { return session }
        unload()
        let start = Date()
        let native = try Model(path: DictationModelStore.url(for: model.file).path)
        let session = try native.session()
        if model.needsLanguageDetector {
            let detectorModel = try Model(path: DictationModelStore.url(for: DictationCatalog.languageDetector).path)
            detector = try detectorModel.langIdSession()
        }
        self.session = session
        modelID = model.id
        Log.dictation.info("loaded \(model.id, privacy: .public) on \(native.backend, privacy: .public) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        return session
    }

    func run(_ samples: [Float], model: DictationModel, plan: DictationLanguagePlan) throws -> TranscriptionEngine.Result {
        let session = try ensure(model)
        var hint: String?
        switch plan {
        case .modelDecides: hint = nil
        case .fixed(let language): hint = language.code
        case .detect(let candidates):
            // Too short to score (under 0.5 s) or any other detector hiccup:
            // fall back to the most-preferred language rather than failing.
            do {
                hint = try detector?.run(samples, options: LangIdOptions(allowed: candidates.map(\.code))).code
            } catch {
                Log.dictation.info("language detection skipped: \(String(describing: error), privacy: .public)")
            }
            if hint == nil { hint = candidates.first?.code }
        }
        let start = Date()
        let transcript = try session.run(samples, options: RunOptions(language: hint))
        let language = transcript.language ?? hint
        Log.dictation.info("transcribed \(samples.count / 16) ms of audio in \(Int(Date().timeIntervalSince(start) * 1000)) ms, \(transcript.text.count) chars, language \(language ?? "?", privacy: .public)")
        return TranscriptionEngine.Result(text: transcript.text, language: language)
    }

    func unload() {
        if modelID != nil { Log.dictation.info("unloaded \(self.modelID ?? "", privacy: .public)") }
        session = nil
        detector = nil
        modelID = nil
    }
}
