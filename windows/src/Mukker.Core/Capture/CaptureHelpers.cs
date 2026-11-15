namespace Mukker.Core.Capture;

public static class ExportNaming
{
    /// <summary>"Mukker 2026-11-15 at 12.34.56.png".</summary>
    public static string BaseName(DateTime when) => $"Mukker {when:yyyy-MM-dd} at {when:HH.mm.ss}";

    /// <summary>A path in <paramref name="directory"/> that doesn't exist yet: " 2", " 3", … on collisions. Never overwrites.</summary>
    public static string UniquePath(string directory, DateTime when, string extension, Func<string, bool>? exists = null)
    {
        exists ??= File.Exists;
        var baseName = BaseName(when);
        var path = Path.Combine(directory, $"{baseName}.{extension}");
        for (var n = 2; exists(path); n++)
            path = Path.Combine(directory, $"{baseName} {n}.{extension}");
        return path;
    }
}

/// <summary>
/// Finds how far a scrolled frame moved relative to the previous one, from per-row luminance
/// signatures, so scrolling capture can append only the new strip.
/// </summary>
public static class ImageStitcher
{
    /// <summary>
    /// Per-row signature: the luminance of every <paramref name="step"/>-th pixel. <paramref name="bgra"/> is
    /// a top-down 32bpp BGRA buffer.
    /// </summary>
    public static byte[][] RowSignatures(byte[] bgra, int width, int height, int stride, int step = 4)
    {
        var cols = (width + step - 1) / step;
        var rows = new byte[height][];
        for (var y = 0; y < height; y++)
        {
            var sig = new byte[cols];
            var o = y * stride;
            for (int x = 0, c = 0; x < width; x += step, c++)
            {
                var i = o + x * 4;
                sig[c] = (byte)((bgra[i + 2] * 299 + bgra[i + 1] * 587 + bgra[i] * 114) / 1000);
            }
            rows[y] = sig;
        }
        return rows;
    }

    private static bool RowsMatch(byte[] a, byte[] b, int tolerance = 6)
    {
        var bad = 0;
        var maxBad = Math.Max(1, a.Length / 50); // allow ~2% of samples to differ (cursor blink, antialiasing)
        for (var i = 0; i < a.Length; i++)
            if (Math.Abs(a[i] - b[i]) > tolerance && ++bad > maxBad) return false;
        return true;
    }

    /// <summary>
    /// The scroll advance in rows between <paramref name="previous"/> and <paramref name="next"/> (same height):
    /// the smallest shift s for which next[r] matches previous[r + s] across the overlap. 0 = no movement,
    /// null = no overlap found (the frames don't line up).
    /// </summary>
    public static int? FindAdvance(byte[][] previous, byte[][] next, int minOverlap = 24)
    {
        var h = Math.Min(previous.Length, next.Length);
        if (h == 0) return null;
        if (Enumerable.Range(0, h).All(r => RowsMatch(previous[r], next[r]))) return 0;
        for (var s = 1; s <= h - minOverlap; s++)
        {
            var overlap = h - s;
            // Cheap pre-check on a few rows before the full comparison.
            if (!RowsMatch(next[0], previous[s]) || !RowsMatch(next[overlap / 2], previous[s + overlap / 2])) continue;
            var ok = true;
            for (var r = 0; r < overlap && ok; r++)
                ok = RowsMatch(next[r], previous[r + s]);
            if (ok) return s;
        }
        return null;
    }
}
