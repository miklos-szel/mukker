using Mukker.Core.Settings;

namespace Mukker.Core.Storage;

public sealed class ClipItem
{
    public long Id { get; set; }
    public ClipKind Kind { get; set; }
    public string? TextContent { get; set; }
    /// <summary>Path relative to the data directory, e.g. "images/&lt;sha&gt;.png".</summary>
    public string? ImagePath { get; set; }
    public int? ImageWidth { get; set; }
    public int? ImageHeight { get; set; }
    public string? PreviewText { get; set; }
    public string? SourceApp { get; set; }
    public DateTime CreatedAt { get; set; }
    public bool Pinned { get; set; }
    public string ContentHash { get; set; } = "";
    public DateTime? LastUsedAt { get; set; }
    /// <summary>Path relative to the data directory: "richtext/&lt;sha&gt;.rtf" or ".html".</summary>
    public string? RichTextPath { get; set; }

    public DateTime EffectiveTimestamp => LastUsedAt ?? CreatedAt;

    public static string KindToDb(ClipKind k) => k switch
    {
        ClipKind.Text => "text",
        ClipKind.Image => "image",
        _ => "file",
    };

    public static ClipKind KindFromDb(string s) => s switch
    {
        "text" => ClipKind.Text,
        "image" => ClipKind.Image,
        _ => ClipKind.File,
    };
}

public sealed class SnippetCollection
{
    public long Id { get; set; }
    public string Name { get; set; } = "";
    public string KeywordPrefix { get; set; } = "";
    public string KeywordSuffix { get; set; } = "";
    public DateTime CreatedAt { get; set; }
}

public sealed class Snippet
{
    public long Id { get; set; }
    public long CollectionId { get; set; }
    public string Name { get; set; } = "";
    public string? Keyword { get; set; }
    public string Content { get; set; } = "";
    public string? Uid { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime UpdatedAt { get; set; }
}

public static class SnippetNaming
{
    public const int MaxLength = 100;
    public const int DefaultLength = 50;

    /// <summary>The default name for a clip turned into a snippet: its first non-blank line, 50 chars.</summary>
    public static string DefaultName(string text)
    {
        var line = text.Split('\n').Select(l => l.Trim()).FirstOrDefault(l => l.Length > 0) ?? "Snippet";
        return line.Length > DefaultLength ? line[..DefaultLength] : line;
    }

    /// <summary>Trim; blank falls back to <paramref name="fallback"/>; capped at 100 characters.</summary>
    public static string Normalize(string? entered, string fallback)
    {
        var n = (entered ?? "").Trim();
        if (n.Length == 0) n = fallback;
        return n.Length > MaxLength ? n[..MaxLength] : n;
    }
}

internal static class DbTime
{
    public static double ToDb(DateTime t) =>
        (t.ToUniversalTime() - DateTime.UnixEpoch).TotalSeconds;

    public static DateTime FromDb(double s) =>
        DateTime.UnixEpoch.AddSeconds(s).ToLocalTime();
}
