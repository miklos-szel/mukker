using Mukker.Core.Clipboard;
using Mukker.Core.Settings;
using Mukker.Core.Storage;

namespace Mukker.Core.Tests;

public sealed class StorageTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "mukker-test-" + Guid.NewGuid().ToString("N"));
    private readonly Database _db = Database.InMemory();
    private readonly ClipboardRepository _repo;

    public StorageTests()
    {
        Directory.CreateDirectory(Path.Combine(_dir, "images"));
        Directory.CreateDirectory(Path.Combine(_dir, "richtext"));
        _repo = new ClipboardRepository(_db, _dir);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { Directory.Delete(_dir, true); } catch { }
    }

    private static ClipItem Text(string t, DateTime at) => new()
    {
        Kind = ClipKind.Text, TextContent = t, PreviewText = ClipText.Preview(t), ContentHash = ClipText.Sha256(t), CreatedAt = at,
    };

    [Fact]
    public void MigrationsApplyInOrder()
    {
        Assert.Equal(new[] { "v1", "v2_lastUsed", "v3_richText", "v4_orderIndex" }, _db.AppliedMigrations());
    }

    [Fact]
    public void MigrationsAreIdempotentOnReopen()
    {
        var path = Path.Combine(_dir, "x.sqlite");
        using (var a = new Database(path)) { }
        using var b = new Database(path);
        Assert.Equal(4, b.AppliedMigrations().Count);
    }

    [Fact]
    public void DuplicateHashTouchesInsteadOfInserting()
    {
        var t0 = new DateTime(2026, 1, 1, 10, 0, 0);
        var (a, newA) = _repo.InsertOrTouch(Text("hello", t0), moveToTop: true);
        _repo.InsertOrTouch(Text("world", t0.AddMinutes(1)), true);
        var (b, newB) = _repo.InsertOrTouch(Text("hello", t0.AddMinutes(2)), true);
        Assert.True(newA);
        Assert.False(newB);
        Assert.Equal(a.Id, b.Id);
        Assert.Equal(2, _repo.Count());
        Assert.Equal("hello", _repo.Page(0, 10)[0].TextContent);
    }

    [Fact]
    public void PinnedSortFirst()
    {
        var t0 = new DateTime(2026, 1, 1);
        var (old, _) = _repo.InsertOrTouch(Text("old", t0), true);
        _repo.InsertOrTouch(Text("new", t0.AddHours(1)), true);
        _repo.SetPinned(old.Id, true);
        var page = _repo.Page(0, 10);
        Assert.Equal("old", page[0].TextContent);
        Assert.Equal("new", page[1].TextContent);
        // NewestText ignores pin order (the translate source).
        Assert.Equal("new", _repo.NewestText()!.TextContent);
    }

    [Fact]
    public void TrimKeepsPinnedAndRemovesOldestAndTheirFiles()
    {
        var t0 = new DateTime(2026, 1, 1);
        File.WriteAllText(Path.Combine(_dir, "images", "a.png"), "x");
        _repo.InsertOrTouch(new ClipItem { Kind = ClipKind.Image, ImagePath = "images/a.png", ContentHash = "a", CreatedAt = t0 }, true);
        var (pinned, _) = _repo.InsertOrTouch(Text("pinned", t0.AddMinutes(1)), true);
        _repo.SetPinned(pinned.Id, true);
        _repo.InsertOrTouch(Text("c", t0.AddMinutes(2)), true);
        _repo.InsertOrTouch(Text("d", t0.AddMinutes(3)), true);
        var removed = _repo.TrimTo(2);
        Assert.Equal(2, removed.Count);
        Assert.False(File.Exists(Path.Combine(_dir, "images", "a.png")));
        var left = _repo.Page(0, 10).Select(i => i.TextContent).ToList();
        Assert.Equal(new[] { "pinned", "d" }, left);
    }

    [Fact]
    public void RetentionSweepPurgesPerKindAndArchivesText()
    {
        var now = new DateTime(2026, 6, 1);
        _repo.InsertOrTouch(Text("ancient", now.AddDays(-40)), true);
        _repo.InsertOrTouch(Text("fresh", now.AddDays(-1)), true);
        var archive = Path.Combine(_dir, "archive");
        var settings = new ClipboardSettings { ForeverHistoryEnabled = true, ForeverHistoryDirectory = archive };
        var svc = new RetentionService(_repo, () => settings);
        Assert.Equal(1, svc.Sweep(now));
        Assert.Equal("fresh", _repo.Page(0, 10).Single().TextContent);
        var file = Directory.GetFiles(archive).Single();
        Assert.Equal("ancient", File.ReadAllText(file));
        Assert.Matches(@"\d{8}-\d{6}_[0-9a-f]{8}\.txt$", file);
    }

    [Fact]
    public void SearchIsCaseInsensitiveSubstringAndEscapesWildcards()
    {
        var t0 = new DateTime(2026, 1, 1);
        _repo.InsertOrTouch(Text("Hello World", t0), true);
        _repo.InsertOrTouch(Text("100% done", t0.AddSeconds(1)), true);
        _repo.InsertOrTouch(Text("100 percent", t0.AddSeconds(2)), true);
        Assert.Single(_repo.Search("world", 0, 10));
        Assert.Single(_repo.Search("100%", 0, 10));
    }

    [Fact]
    public void OrphanSweepRemovesUnreferencedFilesOnly()
    {
        File.WriteAllText(Path.Combine(_dir, "images", "keep.png"), "x");
        File.WriteAllText(Path.Combine(_dir, "images", "orphan.png"), "x");
        _repo.InsertOrTouch(new ClipItem { Kind = ClipKind.Image, ImagePath = "images/keep.png", ContentHash = "k", CreatedAt = DateTime.Now }, true);
        Assert.Equal(1, _repo.RemoveOrphanedSidecarFiles());
        Assert.True(File.Exists(Path.Combine(_dir, "images", "keep.png")));
    }

    [Fact]
    public void FastAppendMergesOntoSecondNewestOnlyWhenNewestIsTheCopy()
    {
        var t0 = new DateTime(2026, 1, 1);
        _repo.InsertOrTouch(Text("first", t0), true);
        _repo.InsertOrTouch(Text("second", t0.AddSeconds(1)), true);
        var plan = FastAppend.Plan(_repo.NewestTexts(2), "second", " ");
        Assert.NotNull(plan);
        Assert.Equal("first second", plan!.Value.Merged);
        Assert.Equal("first", plan.Value.Target.TextContent);
        Assert.Null(FastAppend.Plan(_repo.NewestTexts(2), "not recorded", " "));
    }

    [Fact]
    public void SnippetImportIsIdempotentByNameAndUid()
    {
        var repo = new SnippetRepository(_db);
        var snippets = new[] { new Snippet { Name = "a", Content = "A", Uid = "u1" }, new Snippet { Name = "b", Content = "B", Uid = "u2" } };
        Assert.Equal((2, 0), repo.ImportCollection("Col", "", "", snippets));
        snippets[0].Content = "A2";
        Assert.Equal((0, 2), repo.ImportCollection("Col", "", "", snippets));
        var col = Assert.Single(repo.Collections());
        var stored = repo.Snippets(col.Id);
        Assert.Equal(2, stored.Count);
        Assert.Equal("A2", stored.Single(s => s.Uid == "u1").Content);
    }

    [Fact]
    public void DeletingCollectionCascadesToSnippets()
    {
        var repo = new SnippetRepository(_db);
        var c = repo.CreateCollection("X");
        repo.AddSnippet(c.Id, "n", "v");
        repo.DeleteCollection(c.Id);
        Assert.Empty(repo.AllSnippets());
    }

    [Fact]
    public void SnippetNamingRules()
    {
        Assert.Equal("first line", SnippetNaming.DefaultName("\n  first line \nsecond"));
        Assert.Equal("fallback", SnippetNaming.Normalize("   ", "fallback"));
        Assert.Equal(100, SnippetNaming.Normalize(new string('x', 150), "f").Length);
    }
}
