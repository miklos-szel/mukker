using System.Globalization;
using System.Text;

namespace Mukker.Core.Clipboard;

/// <summary>
/// The Windows "HTML Format" clipboard payload: an ASCII header with byte offsets
/// (StartHTML/EndHTML/StartFragment/EndFragment) followed by UTF-8 HTML.
/// </summary>
public static class CfHtml
{
    /// <summary>Extracts the fragment (or, failing that, the whole HTML) from a CF_HTML payload.</summary>
    public static string? ExtractFragment(byte[] payload)
    {
        var header = Encoding.ASCII.GetString(payload, 0, Math.Min(payload.Length, 512));
        int Offset(string key)
        {
            var i = header.IndexOf(key + ":", StringComparison.Ordinal);
            if (i < 0) return -1;
            var start = i + key.Length + 1;
            var end = start;
            while (end < header.Length && char.IsDigit(header[end])) end++;
            return int.TryParse(header[start..end], NumberStyles.None, CultureInfo.InvariantCulture, out var v) ? v : -1;
        }
        var sf = Offset("StartFragment");
        var ef = Offset("EndFragment");
        if (sf >= 0 && ef > sf && ef <= payload.Length)
            return Encoding.UTF8.GetString(payload, sf, ef - sf);
        var sh = Offset("StartHTML");
        var eh = Offset("EndHTML");
        if (sh >= 0 && eh > sh && eh <= payload.Length)
            return Encoding.UTF8.GetString(payload, sh, eh - sh);
        return null;
    }

    /// <summary>Wraps an HTML fragment in a CF_HTML payload with correct byte offsets.</summary>
    public static byte[] Build(string fragment)
    {
        const string headerTemplate = "Version:0.9\r\nStartHTML:{0:D10}\r\nEndHTML:{1:D10}\r\nStartFragment:{2:D10}\r\nEndFragment:{3:D10}\r\n";
        const string pre = "<html><body>\r\n<!--StartFragment-->";
        const string post = "<!--EndFragment-->\r\n</body></html>";
        var headerLen = string.Format(CultureInfo.InvariantCulture, headerTemplate, 0, 0, 0, 0).Length;
        var fragBytes = Encoding.UTF8.GetByteCount(fragment);
        var startHtml = headerLen;
        var startFrag = startHtml + Encoding.UTF8.GetByteCount(pre);
        var endFrag = startFrag + fragBytes;
        var endHtml = endFrag + Encoding.UTF8.GetByteCount(post);
        var header = string.Format(CultureInfo.InvariantCulture, headerTemplate, startHtml, endHtml, startFrag, endFrag);
        return Encoding.UTF8.GetBytes(header + pre + fragment + post);
    }
}
