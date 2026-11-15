using System.Security.Cryptography;
using System.Text;
using Mukker.Core.Settings;
using Mukker.Core.Storage;

namespace Mukker.Core.Clipboard;

public static class ClipText
{
    public const int PreviewLength = 200;

    public static string Preview(string text) => text.Length <= PreviewLength ? text : text[..PreviewLength];

    public static string Sha256(string text) => Sha256(Encoding.UTF8.GetBytes(text));

    public static string Sha256(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    public static bool IsBlank(string? s) => string.IsNullOrWhiteSpace(s);

    public static string FilesPreview(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return "";
        var first = Path.GetFileName(paths[0].TrimEnd('\\', '/'));
        if (paths.Count == 1) return first;
        return $"{paths.Count} files: {first}, …";
    }

    public static string ImagePreview(int w, int h) => $"Image {w}×{h}";
}

/// <summary>What the monitor saw on the clipboard, before the policy decides whether to keep it.</summary>
public sealed class ClipboardSnapshot
{
    public IReadOnlySet<string> Formats { get; init; } = new HashSet<string>();
    public string? SourceProcess { get; init; }
    /// <summary>Value of the "Chromium internal source URL" format, if any.</summary>
    public string? ChromiumSourceUrl { get; init; }
    /// <summary>Value of "CanIncludeInClipboardHistory" (DWORD) if present.</summary>
    public int? CanIncludeInHistory { get; init; }
}

/// <summary>The single capture policy, mirroring the Mac's shouldRecord.</summary>
public static class CapturePolicy
{
    public static readonly string[] SensitiveFormats =
    [
        "ExcludeClipboardContentFromMonitorProcessing",
        "Clipboard Viewer Ignore",
    ];

    public static bool ShouldRecord(ClipboardSnapshot snap, ClipboardSettings settings)
    {
        if (snap.SourceProcess is { } proc && IsIgnoredApp(proc, settings)) return false;
        if (!settings.IgnoreConcealedItems) return true;
        if (SensitiveFormats.Any(snap.Formats.Contains)) return false;
        if (snap.CanIncludeInHistory == 0) return false;
        if (snap.ChromiumSourceUrl is { } url && IsPasswordManagerExtension(url, settings)) return false;
        return true;
    }

    public static bool IsIgnoredApp(string processName, ClipboardSettings settings)
    {
        var name = Path.GetFileNameWithoutExtension(processName);
        return settings.IgnoredApps.Any(a => string.Equals(a.ProcessName, name, StringComparison.OrdinalIgnoreCase));
    }

    public static bool IsPasswordManagerExtension(string url, ClipboardSettings settings)
    {
        const string prefix = "chrome-extension://";
        if (!url.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return false;
        var rest = url[prefix.Length..];
        var id = rest.Split('/')[0];
        return settings.PasswordManagerExtensions.Any(e => string.Equals(e.ExtensionId, id, StringComparison.OrdinalIgnoreCase));
    }
}

public static class FastAppend
{
    /// <summary>The merged text: previous + separator + current.</summary>
    public static string Merge(string previous, string current, string separator) => previous + separator + current;

    /// <summary>
    /// Decides the merge: the newest text item must be the just-copied text (by hash), otherwise the
    /// monitor hasn't recorded it and the merge would hit the wrong item. Returns the target item
    /// (the second newest) and the merged text, or null.
    /// </summary>
    public static (ClipItem Target, ClipItem Newest, string Merged)? Plan(IReadOnlyList<ClipItem> newestTexts, string copied, string separator)
    {
        if (newestTexts.Count < 2) return null;
        var newest = newestTexts[0];
        if (newest.ContentHash != ClipText.Sha256(copied)) return null;
        var target = newestTexts[1];
        if (target.TextContent is not { } prev) return null;
        return (target, newest, Merge(prev, copied, separator));
    }
}

public static class ForeverHistoryArchive
{
    /// <summary>File name for an archived text item: yyyyMMdd-HHmmss_&lt;hash8&gt;.txt.</summary>
    public static string FileName(ClipItem item) =>
        $"{item.CreatedAt:yyyyMMdd-HHmmss}_{(item.ContentHash.Length >= 8 ? item.ContentHash[..8] : item.ContentHash)}.txt";

    /// <summary>Writes text items about to be deleted. Never overwrites an existing archive file.</summary>
    public static int Archive(IEnumerable<ClipItem> items, string directory)
    {
        var n = 0;
        foreach (var it in items)
        {
            if (it.Kind != ClipKind.Text || it.TextContent is null) continue;
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, FileName(it));
            if (File.Exists(path)) continue;
            File.WriteAllText(path, it.TextContent, new UTF8Encoding(false));
            n++;
        }
        return n;
    }
}

public sealed class RetentionService
{
    private readonly ClipboardRepository _repo;
    private readonly Func<ClipboardSettings> _settings;

    public RetentionService(ClipboardRepository repo, Func<ClipboardSettings> settings)
    {
        _repo = repo;
        _settings = settings;
    }

    /// <summary>Deletes expired unpinned items per kind (and disabled kinds entirely), archiving text first if enabled.</summary>
    public int Sweep(DateTime now)
    {
        var s = _settings();
        var removed = 0;
        foreach (var kind in new[] { ClipKind.Text, ClipKind.Image, ClipKind.File })
        {
            var span = s.RetentionFor(kind);
            if (span is null) continue;
            var cutoff = now - span.Value;
            if (s.ForeverHistoryEnabled && kind == ClipKind.Text)
                ForeverHistoryArchive.Archive(_repo.ExpiredItems(kind, cutoff), s.ForeverHistoryDirectory ?? AppPaths.DefaultForeverHistoryDirectory);
            removed += _repo.PurgeOlderThan(kind, cutoff).Count;
        }
        return removed;
    }

    /// <summary>Trims to the max item count, archiving text first if enabled.</summary>
    public int Trim()
    {
        var s = _settings();
        var removed = _repo.TrimTo(Math.Max(1, s.MaxHistoryItems));
        if (s.ForeverHistoryEnabled)
            ForeverHistoryArchive.Archive(removed, s.ForeverHistoryDirectory ?? AppPaths.DefaultForeverHistoryDirectory);
        return removed.Count;
    }
}
