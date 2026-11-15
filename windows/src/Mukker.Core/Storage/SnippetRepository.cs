using Microsoft.Data.Sqlite;

namespace Mukker.Core.Storage;

public sealed class SnippetRepository
{
    private readonly Database _db;
    public event EventHandler? Changed;

    public SnippetRepository(Database db) => _db = db;

    private static SnippetCollection MapCollection(SqliteDataReader r) => new()
    {
        Id = r.GetInt64(0),
        Name = r.GetString(1),
        KeywordPrefix = r.GetString(2),
        KeywordSuffix = r.GetString(3),
        CreatedAt = DbTime.FromDb(r.GetDouble(4)),
    };

    private static Snippet MapSnippet(SqliteDataReader r) => new()
    {
        Id = r.GetInt64(0),
        CollectionId = r.GetInt64(1),
        Name = r.GetString(2),
        Keyword = r.IsDBNull(3) ? null : r.GetString(3),
        Content = r.GetString(4),
        Uid = r.IsDBNull(5) ? null : r.GetString(5),
        CreatedAt = DbTime.FromDb(r.GetDouble(6)),
        UpdatedAt = DbTime.FromDb(r.GetDouble(7)),
    };

    private const string CollectionCols = "id, name, keywordPrefix, keywordSuffix, createdAt";
    private const string SnippetCols = "id, collectionId, name, keyword, content, uid, createdAt, updatedAt";

    public List<SnippetCollection> Collections()
    {
        var list = new List<SnippetCollection>();
        _db.Read($"SELECT {CollectionCols} FROM collections ORDER BY name COLLATE NOCASE", null, r => list.Add(MapCollection(r)));
        return list;
    }

    public SnippetCollection? Collection(long id)
    {
        SnippetCollection? c = null;
        _db.Read($"SELECT {CollectionCols} FROM collections WHERE id = $id", p => p.AddWithValue("$id", id), r => c = MapCollection(r));
        return c;
    }

    public List<Snippet> Snippets(long collectionId)
    {
        var list = new List<Snippet>();
        _db.Read($"SELECT {SnippetCols} FROM snippets WHERE collectionId = $c ORDER BY name COLLATE NOCASE",
            p => p.AddWithValue("$c", collectionId), r => list.Add(MapSnippet(r)));
        return list;
    }

    public List<Snippet> AllSnippets()
    {
        var list = new List<Snippet>();
        _db.Read($"SELECT {SnippetCols} FROM snippets ORDER BY name COLLATE NOCASE", null, r => list.Add(MapSnippet(r)));
        return list;
    }

    public SnippetCollection CreateCollection(string name, string prefix = "", string suffix = "")
    {
        var c = new SnippetCollection { Name = name, KeywordPrefix = prefix, KeywordSuffix = suffix, CreatedAt = DateTime.Now };
        _db.InTransaction(() =>
        {
            _db.Exec("INSERT INTO collections(name, keywordPrefix, keywordSuffix, createdAt) VALUES ($n, $p, $s, $t)", p =>
            {
                p.AddWithValue("$n", name);
                p.AddWithValue("$p", prefix);
                p.AddWithValue("$s", suffix);
                p.AddWithValue("$t", DbTime.ToDb(c.CreatedAt));
            });
            c.Id = Convert.ToInt64(_db.Scalar("SELECT last_insert_rowid()"));
            return 0;
        });
        Changed?.Invoke(this, EventArgs.Empty);
        return c;
    }

    public void RenameCollection(long id, string name)
    {
        _db.Exec("UPDATE collections SET name = $n WHERE id = $id", p => { p.AddWithValue("$n", name); p.AddWithValue("$id", id); });
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void DeleteCollection(long id)
    {
        _db.Exec("DELETE FROM collections WHERE id = $id", p => p.AddWithValue("$id", id));
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public Snippet AddSnippet(long collectionId, string name, string content, string? keyword = null, string? uid = null)
    {
        var now = DateTime.Now;
        var s = new Snippet { CollectionId = collectionId, Name = name, Content = content, Keyword = keyword, Uid = uid ?? Guid.NewGuid().ToString().ToUpperInvariant(), CreatedAt = now, UpdatedAt = now };
        _db.InTransaction(() =>
        {
            InsertSnippet(s);
            return 0;
        });
        Changed?.Invoke(this, EventArgs.Empty);
        return s;
    }

    private void InsertSnippet(Snippet s)
    {
        _db.Exec("INSERT INTO snippets(collectionId, name, keyword, content, uid, createdAt, updatedAt) VALUES ($c, $n, $k, $v, $u, $t, $t2)", p =>
        {
            p.AddWithValue("$c", s.CollectionId);
            p.AddWithValue("$n", s.Name);
            p.AddWithValue("$k", (object?)s.Keyword ?? DBNull.Value);
            p.AddWithValue("$v", s.Content);
            p.AddWithValue("$u", (object?)s.Uid ?? DBNull.Value);
            p.AddWithValue("$t", DbTime.ToDb(s.CreatedAt));
            p.AddWithValue("$t2", DbTime.ToDb(s.UpdatedAt));
        });
        s.Id = Convert.ToInt64(_db.Scalar("SELECT last_insert_rowid()"));
    }

    public void UpdateSnippet(Snippet s)
    {
        s.UpdatedAt = DateTime.Now;
        _db.Exec("UPDATE snippets SET collectionId = $c, name = $n, keyword = $k, content = $v, updatedAt = $t WHERE id = $id", p =>
        {
            p.AddWithValue("$c", s.CollectionId);
            p.AddWithValue("$n", s.Name);
            p.AddWithValue("$k", (object?)s.Keyword ?? DBNull.Value);
            p.AddWithValue("$v", s.Content);
            p.AddWithValue("$t", DbTime.ToDb(s.UpdatedAt));
            p.AddWithValue("$id", s.Id);
        });
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void DeleteSnippet(long id)
    {
        _db.Exec("DELETE FROM snippets WHERE id = $id", p => p.AddWithValue("$id", id));
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Imports a collection idempotently by (collection name, snippet uid): an existing collection
    /// of that name is reused and a snippet with a known uid is updated rather than duplicated.
    /// Returns (inserted, updated).
    /// </summary>
    public (int Inserted, int Updated) ImportCollection(string name, string prefix, string suffix, IEnumerable<Snippet> snippets)
    {
        var result = _db.InTransaction(() =>
        {
            long? collectionId = null;
            _db.Read("SELECT id FROM collections WHERE name = $n LIMIT 1", p => p.AddWithValue("$n", name), r => collectionId = r.GetInt64(0));
            if (collectionId == null)
            {
                _db.Exec("INSERT INTO collections(name, keywordPrefix, keywordSuffix, createdAt) VALUES ($n, $p, $s, $t)", p =>
                {
                    p.AddWithValue("$n", name);
                    p.AddWithValue("$p", prefix);
                    p.AddWithValue("$s", suffix);
                    p.AddWithValue("$t", DbTime.ToDb(DateTime.Now));
                });
                collectionId = Convert.ToInt64(_db.Scalar("SELECT last_insert_rowid()"));
            }
            int ins = 0, upd = 0;
            foreach (var s in snippets)
            {
                long? existing = null;
                if (!string.IsNullOrEmpty(s.Uid))
                    _db.Read("SELECT id FROM snippets WHERE collectionId = $c AND uid = $u LIMIT 1",
                        p => { p.AddWithValue("$c", collectionId); p.AddWithValue("$u", s.Uid); }, r => existing = r.GetInt64(0));
                if (existing is long id)
                {
                    _db.Exec("UPDATE snippets SET name = $n, keyword = $k, content = $v, updatedAt = $t WHERE id = $id", p =>
                    {
                        p.AddWithValue("$n", s.Name);
                        p.AddWithValue("$k", (object?)s.Keyword ?? DBNull.Value);
                        p.AddWithValue("$v", s.Content);
                        p.AddWithValue("$t", DbTime.ToDb(DateTime.Now));
                        p.AddWithValue("$id", id);
                    });
                    upd++;
                }
                else
                {
                    var now = DateTime.Now;
                    InsertSnippet(new Snippet
                    {
                        CollectionId = collectionId.Value, Name = s.Name, Keyword = s.Keyword, Content = s.Content,
                        Uid = string.IsNullOrEmpty(s.Uid) ? Guid.NewGuid().ToString().ToUpperInvariant() : s.Uid,
                        CreatedAt = now, UpdatedAt = now,
                    });
                    ins++;
                }
            }
            return (ins, upd);
        });
        Changed?.Invoke(this, EventArgs.Empty);
        return result;
    }
}
