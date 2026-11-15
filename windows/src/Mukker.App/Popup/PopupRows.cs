using System;
using System.Globalization;
using System.Linq;
using Mukker.Core.Settings;
using Mukker.Core.Storage;

namespace Mukker.App.Popup;

/// <summary>The single row type the popup list renders.</summary>
public abstract class PopupRow
{
    public virtual bool Selectable => true;
}

public sealed class HeaderRow(string title, bool canGoBack = false) : PopupRow
{
    public string Title { get; } = title;
    public bool CanGoBack { get; } = canGoBack;
    public override bool Selectable => false;
}

public sealed class CollectionRow(SnippetCollection collection, int count) : PopupRow
{
    public SnippetCollection Collection { get; } = collection;
    public string Title => Collection.Name;
    public string Subtitle => count == 1 ? "1 snippet" : $"{count} snippets";
    public string Glyph => ""; // folder
}

public sealed class SnippetRow(Snippet snippet, string collectionName) : PopupRow
{
    public Snippet Snippet { get; } = snippet;
    public string Title => Snippet.Name;
    public string Subtitle => string.IsNullOrEmpty(Snippet.Keyword) ? collectionName : $"{collectionName} · {Snippet.Keyword}";
    public string Glyph => ""; // copy/paste doc
}

public sealed class ClipRow(ClipItem item) : PopupRow
{
    public ClipItem Item { get; } = item;

    public string Title
    {
        get
        {
            var t = (Item.PreviewText ?? Item.TextContent ?? "").Replace("\r", "");
            var line = t.Split('\n').Select(l => l.Trim()).FirstOrDefault(l => l.Length > 0) ?? "";
            return line.Length > 160 ? line[..160] : line;
        }
    }

    public string Subtitle
    {
        get
        {
            var when = Relative(Item.EffectiveTimestamp);
            return string.IsNullOrEmpty(Item.SourceApp) ? when : $"{Item.SourceApp} · {when}";
        }
    }

    public string Glyph => Item.Kind switch
    {
        ClipKind.Image => "", // photo
        ClipKind.File => "",  // document
        _ => Item.RichTextPath != null ? "" : "", // font / text
    };

    public bool Pinned => Item.Pinned;

    public static string Relative(DateTime t)
    {
        var d = DateTime.Now - t;
        if (d.TotalSeconds < 60) return "just now";
        if (d.TotalMinutes < 60) return $"{(int)d.TotalMinutes} min ago";
        if (d.TotalHours < 24 && t.Date == DateTime.Today) return t.ToString("t", CultureInfo.CurrentCulture);
        if (t.Date == DateTime.Today.AddDays(-1)) return "yesterday " + t.ToString("t", CultureInfo.CurrentCulture);
        return t.ToString("MMM d, t", CultureInfo.CurrentCulture);
    }
}
