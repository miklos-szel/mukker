namespace Mukker.Core.Dictation;

/// <summary>
/// The languages Dictation offers. Deliberately just these three: every model in the catalog speaks
/// all of them, and the language detector is restricted to the ones the user ticks.
/// </summary>
public enum DictationLanguage { English, German, Hungarian }

public static class DictationLanguageExtensions
{
    /// <summary>The ISO 639-1 code the engine takes as a hint and the detector returns.</summary>
    public static string Code(this DictationLanguage l) => l switch
    {
        DictationLanguage.English => "en",
        DictationLanguage.German => "de",
        _ => "hu",
    };

    public static string Label(this DictationLanguage l) => l switch
    {
        DictationLanguage.English => "English",
        DictationLanguage.German => "German",
        _ => "Hungarian",
    };

    /// <summary>The language for an ISO code, or null.</summary>
    public static DictationLanguage? FromCode(string code) => code switch
    {
        "en" => DictationLanguage.English,
        "de" => DictationLanguage.German,
        "hu" => DictationLanguage.Hungarian,
        _ => null,
    };
}

/// <summary>One downloadable GGUF file, pinned to an exact Hugging Face commit and checked against its SHA-256.</summary>
public sealed record DictationModelFile(string Repo, string Revision, string FileName, long ByteSize, string Sha256)
{
    /// <summary><c>resolve/&lt;commit&gt;/…</c>, never <c>resolve/main/…</c>, so a re-published file can't change under the hash.</summary>
    public string DownloadUrl => $"https://huggingface.co/{Repo}/resolve/{Revision}/{FileName}";
}

/// <summary>A speech-to-text model the user can pick.</summary>
/// <param name="HonoursLanguage">Parakeet detects the language itself and ignores a hint, so the language
/// settings only apply to models where this is true.</param>
public sealed record DictationModel(string Id, string Name, string Summary, DictationModelFile File, bool HonoursLanguage)
{
    /// <summary>Only a model that takes a hint can use the detector's answer.</summary>
    public bool NeedsLanguageDetector => HonoursLanguage;
}

public static class DictationCatalog
{
    public const string DefaultModelId = "whisper-large-v3-turbo";

    // Sizes, commits and hashes are those of the Mac catalog (Q8_0 quants). Bump all three together.
    public static readonly IReadOnlyList<DictationModel> Models =
    [
        new("whisper-large-v3-turbo", "Whisper Large v3 Turbo",
            "Accurate. Follows the language settings.",
            new("handy-computer/whisper-large-v3-turbo-gguf",
                "18ada752005f5fddef499256f9a458d0b37a203a",
                "whisper-large-v3-turbo-Q8_0.gguf",
                886_381_728,
                "257aa7ec9121c22c167d5e2c49e3e76b4ba0e6e27ebc13074eba0a80f8190220"),
            true),
        new("parakeet-ultra", "Parakeet Ultra",
            "Best accuracy, fast. Detects the language by itself.",
            new("handy-computer/parakeet-ultra-gguf",
                "a1539be1b849ea7463b88343e5277b373d0c4ea9",
                "parakeet-ultra-Q8_0.gguf",
                740_363_168,
                "007a59761e9258779f189df396b50d12b83bb5b79e66df4b955c230d2f2a0a59"),
            false),
        new("whisper-small", "Whisper Small",
            "Small and quick, less accurate. Follows the language settings.",
            new("handy-computer/whisper-small-gguf",
                "4afdc7942ecf1997f359deae48a63506b062eac4",
                "whisper-small-Q8_0.gguf",
                269_751_136,
                "9b9c8811bbcc82a7766f0fb0925614bdacb0923b2cc630daeac17108b655b860"),
            true),
    ];

    /// <summary>VoxLingua107 ECAPA-TDNN — picks the spoken language among the preferred ones for a model that takes a hint.</summary>
    public static readonly DictationModelFile LanguageDetector = new(
        "handy-computer/lang-id-voxlingua107-ecapa-gguf",
        "e59f0f3847e77723b7d58447ef9456fa0c7e9436",
        "lang-id-voxlingua107-ecapa-Q8_0.gguf",
        26_693_632,
        "063e6cb0af3d53085fc7d68356dfde5ecee2ffa7bc79855f7e4ff930081bfe3a");

    /// <summary>The model with this id; an unknown id resolves to the default.</summary>
    public static DictationModel Model(string? id) =>
        Models.FirstOrDefault(m => m.Id == id) ?? Models.First(m => m.Id == DefaultModelId);

    /// <summary>Every file a model needs on disk before it can run.</summary>
    public static IReadOnlyList<DictationModelFile> Files(DictationModel model) =>
        model.NeedsLanguageDetector ? [model.File, LanguageDetector] : [model.File];
}

/// <summary>How the language passed to the model is chosen. Pure; value equality.</summary>
public abstract record DictationLanguagePlan
{
    private DictationLanguagePlan() { }

    /// <summary>Let the model decide (Parakeet).</summary>
    public sealed record ModelDecides : DictationLanguagePlan;

    /// <summary>Pass this language as the hint.</summary>
    public sealed record Fixed(DictationLanguage Language) : DictationLanguagePlan;

    /// <summary>Run the detector restricted to these, then pass its answer.</summary>
    public sealed record Detect(IReadOnlyList<DictationLanguage> Among) : DictationLanguagePlan
    {
        public bool Equals(Detect? other) => other is not null && Among.SequenceEqual(other.Among);
        public override int GetHashCode() => Among.Aggregate(17, (h, l) => h * 31 + (int)l);
    }

    /// <param name="selected">The Language picker; null is "Automatic".</param>
    /// <param name="preferred">The ticked languages; empty means all three.</param>
    /// <param name="forced">A per-language trigger forces that language (only for models that honour a hint).</param>
    public static DictationLanguagePlan Plan(DictationModel model, DictationLanguage? selected,
        IEnumerable<DictationLanguage> preferred, DictationLanguage? forced = null)
    {
        if (!model.HonoursLanguage) return new ModelDecides();
        if (forced is { } f) return new Fixed(f);
        if (selected is { } s) return new Fixed(s);
        var pref = preferred.ToList();
        var candidates = Enum.GetValues<DictationLanguage>().Where(l => pref.Count == 0 || pref.Contains(l)).ToList();
        return candidates.Count == 1 ? new Fixed(candidates[0]) : new Detect(candidates);
    }
}
