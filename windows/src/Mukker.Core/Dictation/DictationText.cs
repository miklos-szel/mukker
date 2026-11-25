using System.Security.Cryptography;

namespace Mukker.Core.Dictation;

/// <summary>Pure helpers shared by the dictation pipeline.</summary>
public static class DictationText
{
    /// <summary>Anything shorter is a stray tap, not speech.</summary>
    public const double MinimumDuration = 0.3;
    public const double SampleRate = 16000;
    /// <summary>A recording is capped at 5 minutes.</summary>
    public const double MaxDuration = 300;

    /// <summary>Trims what the model returns and optionally adds one trailing space.</summary>
    public static string FinalText(string raw, bool appendTrailingSpace)
    {
        var trimmed = raw.Trim();
        if (trimmed.Length == 0) return "";
        return appendTrailingSpace ? trimmed + " " : trimmed;
    }

    /// <summary>RMS mapped onto a perceptual 0…1 scale (-50 dBFS … 0 dBFS).</summary>
    public static float RmsLevel(ReadOnlySpan<float> samples)
    {
        if (samples.IsEmpty) return 0;
        float sum = 0;
        foreach (var s in samples) sum += s * s;
        var mean = sum / samples.Length;
        var db = 10 * MathF.Log10(MathF.Max(mean, 1e-10f));
        return Math.Min(Math.Max((db + 50) / 50, 0), 1);
    }

    /// <summary>Streams the file through SHA-256 (files are up to ~900 MB); lowercase hex, or null when unreadable.</summary>
    public static string? Sha256OfFile(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20);
            return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}

/// <summary>Pure planning for the model store: what is missing, what a download costs, what a delete removes.</summary>
public static class DictationStorePlan
{
    /// <summary>Files of <paramref name="model"/> not yet on disk.</summary>
    public static IReadOnlyList<DictationModelFile> MissingFiles(DictationModel model, Func<DictationModelFile, bool> isPresent) =>
        DictationCatalog.Files(model).Where(f => !isPresent(f)).ToList();

    /// <summary>Bytes still to fetch (the shared detector only counts while missing).</summary>
    public static long RemainingBytes(DictationModel model, Func<DictationModelFile, bool> isPresent) =>
        MissingFiles(model, isPresent).Sum(f => f.ByteSize);

    /// <summary>A model is installed when every file it needs is present.</summary>
    public static bool IsInstalled(DictationModel model, Func<DictationModelFile, bool> isPresent) =>
        MissingFiles(model, isPresent).Count == 0;

    /// <summary>The model's own file, plus the shared language detector only when no other
    /// detector-needing model has its file present.</summary>
    public static IReadOnlyList<DictationModelFile> FilesToDelete(DictationModel model, Func<DictationModelFile, bool> isPresent)
    {
        var doomed = new List<DictationModelFile> { model.File };
        var othersNeedDetector = DictationCatalog.Models.Any(m =>
            m.Id != model.Id && m.NeedsLanguageDetector && isPresent(m.File));
        if (model.NeedsLanguageDetector && !othersNeedDetector) doomed.Add(DictationCatalog.LanguageDetector);
        return doomed;
    }
}
