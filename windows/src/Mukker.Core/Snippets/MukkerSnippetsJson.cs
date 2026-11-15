using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Mukker.Core.Storage;

namespace Mukker.Core.Snippets;

/// <summary>
/// Mukker's own snippet file format, shared with the macOS app (format "mukker.snippets.v1").
/// Pretty-printed with sorted keys and ISO-8601 dates; optional fields are omitted when absent.
/// </summary>
public static class MukkerSnippetsJson
{
    /// <summary>Frozen wire-format string. Changing it makes older exports unreadable.</summary>
    public const string CurrentFormat = "mukker.snippets.v1";
    public static readonly IReadOnlySet<string> AcceptedFormats = new HashSet<string> { CurrentFormat };
    public const long MaxFileBytes = 20 * 1024 * 1024;

    public sealed record ExportedSnippet(string Name, string Content, string? Keyword, string? Uid);
    public sealed record ExportedCollection(string Name, string KeywordPrefix, string KeywordSuffix, IReadOnlyList<ExportedSnippet> Snippets);

    public sealed class ImportException(string message) : Exception(message);

    public static string Export(IEnumerable<ExportedCollection> collections, DateTime exportedAt)
    {
        // Keys inserted alphabetically so the output has sorted keys, like the Mac encoder.
        var cols = new JsonArray();
        foreach (var c in collections)
        {
            var snippets = new JsonArray();
            foreach (var s in c.Snippets)
            {
                var o = new JsonObject { ["content"] = s.Content };
                if (s.Keyword != null) o["keyword"] = s.Keyword;
                o["name"] = s.Name;
                if (s.Uid != null) o["uid"] = s.Uid;
                snippets.Add(o);
            }
            cols.Add(new JsonObject
            {
                ["keywordPrefix"] = c.KeywordPrefix,
                ["keywordSuffix"] = c.KeywordSuffix,
                ["name"] = c.Name,
                ["snippets"] = snippets,
            });
        }
        var root = new JsonObject
        {
            ["collections"] = cols,
            ["exportedAt"] = exportedAt.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
            ["format"] = CurrentFormat,
        };
        return root.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        });
    }

    public static string Export(SnippetRepository repo, IReadOnlyCollection<long>? collectionIds, DateTime exportedAt)
    {
        var cols = repo.Collections()
            .Where(c => collectionIds == null || collectionIds.Contains(c.Id))
            .Select(c => new ExportedCollection(c.Name, c.KeywordPrefix, c.KeywordSuffix,
                repo.Snippets(c.Id).Select(s => new ExportedSnippet(s.Name, s.Content, s.Keyword, s.Uid)).ToList()))
            .ToList();
        return Export(cols, exportedAt);
    }

    public static IReadOnlyList<ExportedCollection> Parse(string json)
    {
        JsonNode? root;
        try { root = JsonNode.Parse(json); }
        catch (JsonException e) { throw new ImportException($"The file is not valid JSON: {e.Message}"); }
        if (root is not JsonObject obj) throw new ImportException("The file is not a Mukker snippets export.");
        var format = obj["format"]?.GetValue<string>();
        if (format == null || !AcceptedFormats.Contains(format))
            throw new ImportException($"Unsupported format \"{format ?? "(none)"}\".");
        var result = new List<ExportedCollection>();
        foreach (var c in obj["collections"]?.AsArray() ?? [])
        {
            if (c is not JsonObject co) continue;
            var snippets = new List<ExportedSnippet>();
            foreach (var s in co["snippets"]?.AsArray() ?? [])
            {
                if (s is not JsonObject so) continue;
                snippets.Add(new ExportedSnippet(
                    so["name"]?.GetValue<string>() ?? "",
                    so["content"]?.GetValue<string>() ?? "",
                    so["keyword"]?.GetValue<string>(),
                    so["uid"]?.GetValue<string>()));
            }
            result.Add(new ExportedCollection(
                co["name"]?.GetValue<string>() ?? "Imported",
                co["keywordPrefix"]?.GetValue<string>() ?? "",
                co["keywordSuffix"]?.GetValue<string>() ?? "",
                snippets));
        }
        return result;
    }

    /// <summary>Imports a file into the repository (idempotent by collection name + uid). Returns the snippet count.</summary>
    public static int ImportFile(string path, SnippetRepository repo)
    {
        var info = new FileInfo(path);
        if (info.Length > MaxFileBytes)
            throw new ImportException("The file is too large to import (the limit is 20 MB).");
        var cols = Parse(File.ReadAllText(path));
        var count = 0;
        foreach (var c in cols)
        {
            repo.ImportCollection(c.Name, c.KeywordPrefix, c.KeywordSuffix,
                c.Snippets.Select(s => new Snippet { Name = SnippetNaming.Normalize(s.Name, "Snippet"), Content = s.Content, Keyword = s.Keyword, Uid = s.Uid }));
            count += c.Snippets.Count;
        }
        return count;
    }
}
