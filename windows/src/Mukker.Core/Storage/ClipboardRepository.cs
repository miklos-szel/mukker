using Microsoft.Data.Sqlite;
using Mukker.Core.Clipboard;
using Mukker.Core.Settings;

namespace Mukker.Core.Storage;

/// <summary>
/// The only owner of the clip_items table. Every deletion path also removes the row's sidecar
/// files (image PNG, rich text), so deleting never leaks disk.
/// </summary>
public sealed class ClipboardRepository
{
    private const string Columns =
        "id, kind, textContent, imagePath, imageWidth, imageHeight, previewText, sourceApp, createdAt, pinned, contentHash, lastUsedAt, richTextPath";
    private const string Order = "ORDER BY pinned DESC, COALESCE(lastUsedAt, createdAt) DESC";

    private readonly Database _db;
    private readonly string _dataDirectory;

    /// <summary>Fires after any change to the history.</summary>
    public event EventHandler? Changed;

    public ClipboardRepository(Database db, string dataDirectory)
    {
        _db = db;
        _dataDirectory = dataDirectory;
    }

    public string Resolve(string relative) => Path.Combine(_dataDirectory, relative.Replace('/', Path.DirectorySeparatorChar));

    private static ClipItem Map(SqliteDataReader r) => new()
    {
        Id = r.GetInt64(0),
        Kind = ClipItem.KindFromDb(r.GetString(1)),
        TextContent = r.IsDBNull(2) ? null : r.GetString(2),
        ImagePath = r.IsDBNull(3) ? null : r.GetString(3),
        ImageWidth = r.IsDBNull(4) ? null : r.GetInt32(4),
        ImageHeight = r.IsDBNull(5) ? null : r.GetInt32(5),
        PreviewText = r.IsDBNull(6) ? null : r.GetString(6),
        SourceApp = r.IsDBNull(7) ? null : r.GetString(7),
        CreatedAt = DbTime.FromDb(r.GetDouble(8)),
        Pinned = r.GetBoolean(9),
        ContentHash = r.GetString(10),
        LastUsedAt = r.IsDBNull(11) ? null : DbTime.FromDb(r.GetDouble(11)),
        RichTextPath = r.IsDBNull(12) ? null : r.GetString(12),
    };

    private List<ClipItem> Query(string where, Action<SqliteParameterCollection>? bind = null)
    {
        var list = new List<ClipItem>();
        _db.Read($"SELECT {Columns} FROM clip_items {where}", bind, r => list.Add(Map(r)));
        return list;
    }

    public ClipItem? Get(long id) => Query("WHERE id = $id", p => p.AddWithValue("$id", id)).FirstOrDefault();

    public ClipItem? FindByHash(string hash) =>
        Query("WHERE contentHash = $h LIMIT 1", p => p.AddWithValue("$h", hash)).FirstOrDefault();

    /// <summary>History in display order: pinned first, then most recently used/created.</summary>
    public List<ClipItem> Page(int offset, int limit) =>
        Query($"{Order} LIMIT $l OFFSET $o", p => { p.AddWithValue("$l", limit); p.AddWithValue("$o", offset); });

    /// <summary>Case-insensitive substring search over preview, text and source app.</summary>
    public List<ClipItem> Search(string query, int offset, int limit)
    {
        var like = "%" + query.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_") + "%";
        return Query(
            $"WHERE previewText LIKE $q ESCAPE '\\' OR textContent LIKE $q ESCAPE '\\' OR sourceApp LIKE $q ESCAPE '\\' {Order} LIMIT $l OFFSET $o",
            p => { p.AddWithValue("$q", like); p.AddWithValue("$l", limit); p.AddWithValue("$o", offset); });
    }

    public int Count() => Convert.ToInt32(_db.Scalar("SELECT COUNT(*) FROM clip_items"));

    /// <summary>The newest text item by effective timestamp, ignoring pin order (the translate source).</summary>
    public ClipItem? NewestText() =>
        Query("WHERE kind = 'text' ORDER BY COALESCE(lastUsedAt, createdAt) DESC LIMIT 1").FirstOrDefault();

    /// <summary>The newest two text items by creation (fast append merges onto the second).</summary>
    public List<ClipItem> NewestTexts(int count) =>
        Query("WHERE kind = 'text' ORDER BY createdAt DESC, id DESC LIMIT $n", p => p.AddWithValue("$n", count));

    /// <summary>
    /// Inserts <paramref name="item"/> unless an item with the same hash exists. A duplicate is
    /// bumped (when <paramref name="moveToTop"/>) and gains rich text it lacked.
    /// Returns the stored item and whether it is new.
    /// </summary>
    public (ClipItem Item, bool IsNew) InsertOrTouch(ClipItem item, bool moveToTop)
    {
        var result = _db.InTransaction(() =>
        {
            var existing = FindByHash(item.ContentHash);
            if (existing != null)
            {
                if (moveToTop)
                {
                    existing.LastUsedAt = item.CreatedAt;
                    _db.Exec("UPDATE clip_items SET lastUsedAt = $t WHERE id = $id", p =>
                    {
                        p.AddWithValue("$t", DbTime.ToDb(item.CreatedAt));
                        p.AddWithValue("$id", existing.Id);
                    });
                }
                return (existing, false);
            }
            _db.Exec("""
                INSERT INTO clip_items(kind, textContent, imagePath, imageWidth, imageHeight, previewText, sourceApp, createdAt, pinned, contentHash, lastUsedAt, richTextPath)
                VALUES ($kind, $text, $img, $w, $h, $prev, $src, $created, $pinned, $hash, $last, $rtf)
                """, p =>
            {
                p.AddWithValue("$kind", ClipItem.KindToDb(item.Kind));
                p.AddWithValue("$text", (object?)item.TextContent ?? DBNull.Value);
                p.AddWithValue("$img", (object?)item.ImagePath ?? DBNull.Value);
                p.AddWithValue("$w", (object?)item.ImageWidth ?? DBNull.Value);
                p.AddWithValue("$h", (object?)item.ImageHeight ?? DBNull.Value);
                p.AddWithValue("$prev", (object?)item.PreviewText ?? DBNull.Value);
                p.AddWithValue("$src", (object?)item.SourceApp ?? DBNull.Value);
                p.AddWithValue("$created", DbTime.ToDb(item.CreatedAt));
                p.AddWithValue("$pinned", item.Pinned);
                p.AddWithValue("$hash", item.ContentHash);
                p.AddWithValue("$last", item.LastUsedAt is { } l ? DbTime.ToDb(l) : DBNull.Value);
                p.AddWithValue("$rtf", (object?)item.RichTextPath ?? DBNull.Value);
            });
            item.Id = Convert.ToInt64(_db.Scalar("SELECT last_insert_rowid()"));
            return (item, true);
        });
        Changed?.Invoke(this, EventArgs.Empty);
        return result;
    }

    public void SetRichTextPath(long id, string relativePath)
    {
        _db.Exec("UPDATE clip_items SET richTextPath = $p WHERE id = $id", p =>
        {
            p.AddWithValue("$p", relativePath);
            p.AddWithValue("$id", id);
        });
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Touch(long id, DateTime when)
    {
        _db.Exec("UPDATE clip_items SET lastUsedAt = $t WHERE id = $id", p =>
        {
            p.AddWithValue("$t", DbTime.ToDb(when));
            p.AddWithValue("$id", id);
        });
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void SetPinned(long id, bool pinned)
    {
        _db.Exec("UPDATE clip_items SET pinned = $p WHERE id = $id", p =>
        {
            p.AddWithValue("$p", pinned);
            p.AddWithValue("$id", id);
        });
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Replaces a text item's content (fast append), its hash and preview; drops stale rich text.</summary>
    public void UpdateText(long id, string text, string hash)
    {
        var old = Get(id);
        _db.Exec("UPDATE clip_items SET textContent = $t, contentHash = $h, previewText = $p, richTextPath = NULL WHERE id = $id", p =>
        {
            p.AddWithValue("$t", text);
            p.AddWithValue("$h", hash);
            p.AddWithValue("$p", ClipText.Preview(text));
            p.AddWithValue("$id", id);
        });
        if (old?.RichTextPath != null) DeleteFileIfUnreferenced(old.RichTextPath);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Delete(long id)
    {
        var item = Get(id);
        if (item == null) return;
        DeleteRows([item]);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Deletes every unpinned item ("Clear History…"). Returns the deleted items.</summary>
    public List<ClipItem> ClearUnpinned()
    {
        var victims = Query("WHERE pinned = 0");
        DeleteRows(victims);
        Changed?.Invoke(this, EventArgs.Empty);
        return victims;
    }

    /// <summary>Keeps at most <paramref name="max"/> items, deleting the oldest unpinned ones.</summary>
    public List<ClipItem> TrimTo(int max)
    {
        var total = Count();
        if (total <= max) return [];
        var victims = Query("WHERE pinned = 0 ORDER BY COALESCE(lastUsedAt, createdAt) ASC LIMIT $n",
            p => p.AddWithValue("$n", total - max));
        DeleteRows(victims);
        if (victims.Count > 0) Changed?.Invoke(this, EventArgs.Empty);
        return victims;
    }

    /// <summary>Unpinned items of <paramref name="kind"/> whose effective timestamp is before the cutoff.</summary>
    public List<ClipItem> ExpiredItems(ClipKind kind, DateTime cutoff) =>
        Query("WHERE pinned = 0 AND kind = $k AND COALESCE(lastUsedAt, createdAt) < $c", p =>
        {
            p.AddWithValue("$k", ClipItem.KindToDb(kind));
            p.AddWithValue("$c", DbTime.ToDb(cutoff));
        });

    public List<ClipItem> PurgeOlderThan(ClipKind kind, DateTime cutoff)
    {
        var victims = ExpiredItems(kind, cutoff);
        DeleteRows(victims);
        if (victims.Count > 0) Changed?.Invoke(this, EventArgs.Empty);
        return victims;
    }

    private void DeleteRows(IReadOnlyCollection<ClipItem> items)
    {
        if (items.Count == 0) return;
        _db.InTransaction(() =>
        {
            foreach (var it in items)
                _db.Exec("DELETE FROM clip_items WHERE id = $id", p => p.AddWithValue("$id", it.Id));
            return 0;
        });
        foreach (var it in items)
        {
            if (it.ImagePath != null) DeleteFileIfUnreferenced(it.ImagePath);
            if (it.RichTextPath != null) DeleteFileIfUnreferenced(it.RichTextPath);
        }
    }

    private void DeleteFileIfUnreferenced(string relative)
    {
        var refs = Convert.ToInt64(_db.Scalar(
            "SELECT COUNT(*) FROM clip_items WHERE imagePath = $p OR richTextPath = $p",
            p => p.AddWithValue("$p", relative)));
        if (refs > 0) return;
        try { File.Delete(Resolve(relative)); } catch { /* best effort */ }
    }

    /// <summary>Removes image/rich-text files that no row references (crash leftovers). Run at launch.</summary>
    public int RemoveOrphanedSidecarFiles()
    {
        var referenced = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        _db.Read("SELECT imagePath, richTextPath FROM clip_items", null, r =>
        {
            if (!r.IsDBNull(0)) referenced.Add(r.GetString(0));
            if (!r.IsDBNull(1)) referenced.Add(r.GetString(1));
        });
        var removed = 0;
        foreach (var sub in new[] { "images", "richtext" })
        {
            var dir = Path.Combine(_dataDirectory, sub);
            if (!Directory.Exists(dir)) continue;
            foreach (var f in Directory.EnumerateFiles(dir))
            {
                var rel = sub + "/" + Path.GetFileName(f);
                if (referenced.Contains(rel)) continue;
                try { File.Delete(f); removed++; } catch { /* ignore */ }
            }
        }
        return removed;
    }
}
