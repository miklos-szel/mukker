import Foundation

/// The languages Dictation offers. Deliberately just these three: every
/// model in the catalog speaks all of them, and the language detector is
/// restricted to the ones the user ticks.
enum DictationLanguage: String, CaseIterable, Identifiable, Codable {
    case english = "en"
    case german = "de"
    case hungarian = "hu"

    var id: String { rawValue }

    /// The ISO 639-1 code transcribe.cpp takes as a hint and the detector returns.
    var code: String { rawValue }

    var label: String {
        switch self {
        case .english: return "English"
        case .german: return "German"
        case .hungarian: return "Hungarian"
        }
    }
}

/// One downloadable GGUF file, pinned to an exact Hugging Face commit and
/// checked against its SHA-256 before it is used.
struct DictationModelFile: Equatable {
    let repo: String
    let revision: String
    let fileName: String
    let byteSize: Int64
    let sha256: String

    /// `resolve/<commit>/…`, never `resolve/main/…`, so a re-published file can't
    /// change underneath the hash.
    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(fileName)")!
    }
}

/// A speech-to-text model the user can pick. All run through transcribe.cpp.
struct DictationModel: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let file: DictationModelFile
    /// Parakeet detects the language itself and ignores a hint ("accepted
    /// but does not change the output", per transcribe.cpp), so the language
    /// settings only apply to models where this is true.
    let honoursLanguage: Bool

    /// Whether the language detector must be downloaded alongside: only a
    /// model that takes a hint can use its answer.
    var needsLanguageDetector: Bool { honoursLanguage }
}

enum DictationCatalog {
    nonisolated static let defaultModelID = "whisper-large-v3-turbo"

    // Sizes, commits and hashes were read from the Hugging Face API
    // (`/api/models/<repo>?blobs=true`) for the Q8_0 quant — the quant
    // Handy's catalog defaults to. Bump all three together.
    nonisolated static let models: [DictationModel] = [
        DictationModel(
            id: "whisper-large-v3-turbo",
            name: "Whisper Large v3 Turbo",
            summary: "Accurate. Follows the language settings.",
            file: DictationModelFile(
                repo: "handy-computer/whisper-large-v3-turbo-gguf",
                revision: "18ada752005f5fddef499256f9a458d0b37a203a",
                fileName: "whisper-large-v3-turbo-Q8_0.gguf",
                byteSize: 886_381_728,
                sha256: "257aa7ec9121c22c167d5e2c49e3e76b4ba0e6e27ebc13074eba0a80f8190220"),
            honoursLanguage: true),
        DictationModel(
            id: "parakeet-ultra",
            name: "Parakeet Ultra",
            summary: "Best accuracy, fast. Detects the language by itself.",
            file: DictationModelFile(
                repo: "handy-computer/parakeet-ultra-gguf",
                revision: "a1539be1b849ea7463b88343e5277b373d0c4ea9",
                fileName: "parakeet-ultra-Q8_0.gguf",
                byteSize: 740_363_168,
                sha256: "007a59761e9258779f189df396b50d12b83bb5b79e66df4b955c230d2f2a0a59"),
            honoursLanguage: false),
        DictationModel(
            id: "whisper-small",
            name: "Whisper Small",
            summary: "Small and quick, less accurate. Follows the language settings.",
            file: DictationModelFile(
                repo: "handy-computer/whisper-small-gguf",
                revision: "4afdc7942ecf1997f359deae48a63506b062eac4",
                fileName: "whisper-small-Q8_0.gguf",
                byteSize: 269_751_136,
                sha256: "9b9c8811bbcc82a7766f0fb0925614bdacb0923b2cc630daeac17108b655b860"),
            honoursLanguage: true)
    ]

    /// VoxLingua107 ECAPA-TDNN — picks the spoken language among the
    /// preferred ones for a model that takes a hint.
    nonisolated static let languageDetector = DictationModelFile(
        repo: "handy-computer/lang-id-voxlingua107-ecapa-gguf",
        revision: "e59f0f3847e77723b7d58447ef9456fa0c7e9436",
        fileName: "lang-id-voxlingua107-ecapa-Q8_0.gguf",
        byteSize: 26_693_632,
        sha256: "063e6cb0af3d53085fc7d68356dfde5ecee2ffa7bc79855f7e4ff930081bfe3a")

    nonisolated static func model(id: String) -> DictationModel {
        models.first { $0.id == id } ?? models.first { $0.id == defaultModelID }!
    }

    /// Every file a model needs on disk before it can run.
    nonisolated static func files(for model: DictationModel) -> [DictationModelFile] {
        model.needsLanguageDetector ? [model.file, languageDetector] : [model.file]
    }
}

/// How the language passed to the model is chosen. Pure, so it is tested
/// without a model.
enum DictationLanguagePlan: Equatable {
    /// Let the model decide (Parakeet, or nothing narrower is known).
    case modelDecides
    /// Pass this language as the hint.
    case fixed(DictationLanguage)
    /// Run the detector restricted to these, then pass its answer.
    case detect(among: [DictationLanguage])

    /// - `selected`: the Language picker; nil is "Automatic".
    /// - `preferred`: the ticked languages; empty means all three.
    nonisolated static func plan(model: DictationModel,
                                 selected: DictationLanguage?,
                                 preferred: [DictationLanguage]) -> DictationLanguagePlan {
        guard model.honoursLanguage else { return .modelDecides }
        if let selected { return .fixed(selected) }
        let candidates = DictationLanguage.allCases.filter { preferred.isEmpty || preferred.contains($0) }
        if candidates.count == 1 { return .fixed(candidates[0]) }
        return .detect(among: candidates)
    }
}
