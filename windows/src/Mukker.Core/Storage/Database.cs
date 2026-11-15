using Microsoft.Data.Sqlite;

namespace Mukker.Core.Storage;

/// <summary>
/// The SQLite database. The schema is owned by <see cref="Migrations"/>: add a new entry, never edit an
/// existing one. The tables and indexes match the macOS app's v1–v4 migrations.
/// </summary>
public sealed class Database : IDisposable
{
    private readonly SqliteConnection _conn;
    private readonly object _lock = new();
    private SqliteTransaction? _tx;

    internal static readonly (string Name, string Sql)[] Migrations =
    [
        ("v1", """
            CREATE TABLE clip_items(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              kind TEXT NOT NULL,
              textContent TEXT,
              imagePath TEXT,
              imageWidth INTEGER,
              imageHeight INTEGER,
              previewText TEXT,
              sourceApp TEXT,
              createdAt DOUBLE NOT NULL,
              pinned BOOLEAN NOT NULL DEFAULT 0,
              contentHash TEXT NOT NULL);
            CREATE INDEX idx_clip_created ON clip_items(createdAt);
            CREATE INDEX idx_clip_hash ON clip_items(contentHash);
            CREATE TABLE collections(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              keywordPrefix TEXT NOT NULL DEFAULT '',
              keywordSuffix TEXT NOT NULL DEFAULT '',
              createdAt DOUBLE NOT NULL);
            CREATE TABLE snippets(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              collectionId INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
              name TEXT NOT NULL,
              keyword TEXT,
              content TEXT NOT NULL,
              uid TEXT,
              createdAt DOUBLE NOT NULL,
              updatedAt DOUBLE NOT NULL);
            CREATE INDEX idx_snip_collection ON snippets(collectionId);
            """),
        ("v2_lastUsed", """
            ALTER TABLE clip_items ADD COLUMN lastUsedAt DOUBLE;
            CREATE INDEX idx_clip_lastUsed ON clip_items(lastUsedAt);
            """),
        ("v3_richText", "ALTER TABLE clip_items ADD COLUMN richTextPath TEXT;"),
        ("v4_orderIndex", "CREATE INDEX idx_clip_order ON clip_items(pinned, COALESCE(lastUsedAt, createdAt));"),
    ];

    public Database(string path)
    {
        var cs = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = path == ":memory:" ? SqliteOpenMode.Memory : SqliteOpenMode.ReadWriteCreate,
            ForeignKeys = true,
            Pooling = false,
        }.ToString();
        _conn = new SqliteConnection(cs);
        _conn.Open();
        Exec("PRAGMA journal_mode=WAL;");
        Migrate();
    }

    public static Database InMemory() => new(":memory:");

    private void Migrate()
    {
        Exec("CREATE TABLE IF NOT EXISTS schema_migrations(identifier TEXT NOT NULL PRIMARY KEY);");
        var applied = new HashSet<string>();
        using (var cmd = _conn.CreateCommand())
        {
            cmd.CommandText = "SELECT identifier FROM schema_migrations";
            using var r = cmd.ExecuteReader();
            while (r.Read()) applied.Add(r.GetString(0));
        }
        foreach (var (name, sql) in Migrations)
        {
            if (applied.Contains(name)) continue;
            using var tx = _conn.BeginTransaction();
            using (var cmd = _conn.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = sql;
                cmd.ExecuteNonQuery();
            }
            using (var cmd = _conn.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = "INSERT INTO schema_migrations(identifier) VALUES ($n)";
                cmd.Parameters.AddWithValue("$n", name);
                cmd.ExecuteNonQuery();
            }
            tx.Commit();
        }
    }

    public IReadOnlyList<string> AppliedMigrations()
    {
        var list = new List<string>();
        Read("SELECT identifier FROM schema_migrations ORDER BY rowid", null, r => list.Add(r.GetString(0)));
        return list;
    }

    public int Exec(string sql, Action<SqliteParameterCollection>? bind = null)
    {
        lock (_lock)
        {
            using var cmd = _conn.CreateCommand();
            cmd.Transaction = _tx;
            cmd.CommandText = sql;
            bind?.Invoke(cmd.Parameters);
            return cmd.ExecuteNonQuery();
        }
    }

    public object? Scalar(string sql, Action<SqliteParameterCollection>? bind = null)
    {
        lock (_lock)
        {
            using var cmd = _conn.CreateCommand();
            cmd.Transaction = _tx;
            cmd.CommandText = sql;
            bind?.Invoke(cmd.Parameters);
            var v = cmd.ExecuteScalar();
            return v is DBNull ? null : v;
        }
    }

    public void Read(string sql, Action<SqliteParameterCollection>? bind, Action<SqliteDataReader> row)
    {
        lock (_lock)
        {
            using var cmd = _conn.CreateCommand();
            cmd.Transaction = _tx;
            cmd.CommandText = sql;
            bind?.Invoke(cmd.Parameters);
            using var r = cmd.ExecuteReader();
            while (r.Read()) row(r);
        }
    }

    /// <summary>Runs <paramref name="work"/> in one transaction, holding the connection lock.</summary>
    public T InTransaction<T>(Func<T> work)
    {
        lock (_lock)
        {
            if (_tx != null) return work(); // nested: join the outer transaction
            using var tx = _conn.BeginTransaction();
            _tx = tx;
            try
            {
                var result = work();
                tx.Commit();
                return result;
            }
            finally { _tx = null; }
        }
    }

    public void Dispose() => _conn.Dispose();
}
