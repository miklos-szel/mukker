using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Mukker.Core.Clipboard;

/// <summary>
/// Strips every element, attribute and CSS construct from copied HTML that could make a renderer
/// load something (tracking pixels, remote fonts, frames, scripts). Links (&lt;a href&gt;) are kept.
/// A port of the macOS app's HTMLSanitizer, regex for regex.
/// </summary>
public static class HtmlSanitizer
{
    public static string Sanitize(string html)
    {
        var s = html;
        s = Comments.Replace(s, "");
        s = UnterminatedComment.Replace(s, "");
        s = DroppedContainers.Replace(s, "");
        s = Transform(StyleBlocks, s, m => m.Groups[1].Value + SanitizeCss(m.Groups[2].Value) + m.Groups[3].Value);
        s = Transform(Tags, s, SanitizeTag, gap => UnparsedTagStart.Replace(gap, "&lt;"));
        return s;
    }

    private static readonly HashSet<string> DroppedTagNames =
    [
        "img", "image", "picture", "source", "video", "audio", "track", "iframe", "frame",
        "frameset", "object", "embed", "applet", "param", "script", "link", "base", "svg",
        "use", "math", "noscript", "template", "portal", "fencedframe",
    ];

    private static readonly HashSet<string> DroppedAttributes =
    [
        "src", "srcset", "imagesrcset", "srcdoc", "data", "background", "poster", "lowsrc",
        "dynsrc", "longdesc", "codebase", "archive", "classid", "formaction", "action",
        "xlink:href", "icon", "manifest", "ping", "content", "attributionsrc",
    ];

    private static readonly HashSet<string> HrefAllowedTags = ["a", "area"];

    private static string SanitizeTag(Match m)
    {
        var isClosing = m.Groups[1].Length > 0;
        var name = m.Groups[2].Value;
        var lower = name.ToLowerInvariant();
        if (DroppedTagNames.Contains(lower)) return "";
        if (isClosing) return $"</{name}>";
        var attrs = m.Groups[3].Value;
        if (lower == "meta" && attrs.Contains("http-equiv", StringComparison.OrdinalIgnoreCase)) return "";

        var kept = new List<string>();
        foreach (Match a in Attribute.Matches(attrs))
        {
            var attrName = a.Groups[1].Value.ToLowerInvariant();
            if (DroppedAttributes.Contains(attrName) || attrName.StartsWith("on", StringComparison.Ordinal)) continue;
            if (attrName == "href" && !HrefAllowedTags.Contains(lower)) continue;
            if (attrName == "style")
            {
                if (!a.Groups[2].Success) continue;
                var value = Unquote(a.Groups[2].Value);
                if (value.Contains('&') || value.Contains('\\')) continue;
                var clean = SanitizeCss(value).Replace("\"", "'");
                kept.Add($"style=\"{clean}\"");
                continue;
            }
            kept.Add(a.Value);
        }
        var selfClosing = attrs.Trim().EndsWith('/');
        var body = kept.Count == 0 ? "" : " " + string.Join(" ", kept);
        return $"<{name}{body}{(selfClosing ? " /" : "")}>";
    }

    private static string Unquote(string v)
    {
        if (v.Length >= 2 && (v[0] == '"' || v[0] == '\'') && v[^1] == v[0]) return v[1..^1];
        return v;
    }

    public static string SanitizeCss(string css)
    {
        var s = UnescapeCss(css);
        s = CssComments.Replace(s, "");
        s = CssImport.Replace(s, "");
        s = CssUrl.Replace(s, "none");
        s = CssLoadingCall.Replace(s, "none");
        s = CssLoadingFunction.Replace(s, "x-blocked(");
        s = CssImportKeyword.Replace(s, "@x-blocked");
        return s;
    }

    private static string UnescapeCss(string css)
    {
        if (!css.Contains('\\')) return css;
        return Transform(CssEscape, css, m =>
        {
            if (m.Groups[1].Success &&
                int.TryParse(m.Groups[1].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var code) &&
                code != 0 && code <= 0x10FFFF && (code < 0xD800 || code > 0xDFFF))
                return char.ConvertFromUtf32(code);
            if (m.Groups[2].Success) return m.Groups[2].Value;
            return "";
        });
    }

    private static Regex R(string p) => new(p, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private const string AttrChars = """(?:[^>"']|"[^"]*"|'[^']*')*""";
    private static readonly Regex Comments = R(@"<!--[\s\S]*?-->");
    private static readonly Regex UnterminatedComment = R(@"<!--[\s\S]*$");
    private static readonly Regex DroppedContainers = R(
        @"<(script|iframe|object|video|audio|picture|svg|math|noscript|template|frameset|applet|noembed|noframes)\b"
        + AttrChars + @">[\s\S]*?</\1\s*>");
    private static readonly Regex StyleBlocks = R(@"(<style\b" + AttrChars + @">)([\s\S]*?)(</style\s*>|$)");
    private static readonly Regex Tags = R(@"<(/?)([a-z][a-z0-9:_-]*)(" + AttrChars + ")>");
    private static readonly Regex UnparsedTagStart = R(@"<(?=/?[a-z])");
    private static readonly Regex Attribute = R("""([^\s"'>/=]+)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s"'>]+))?""");
    private static readonly Regex CssEscape = R(@"\\(?:([0-9a-f]{1,6})\s?|(.)|$)");
    private static readonly Regex CssComments = R(@"/\*[\s\S]*?(?:\*/|$)");
    private static readonly Regex CssImport = R(@"@import\b[^;]*;?");
    private static readonly Regex CssUrl = R("""url\s*\(\s*(?:"[^"]*"|'[^']*'|[^)]*)\s*\)""");
    private const string CssLoadingNames = @"(?:url|(?:-webkit-)?image-set|image|(?:-webkit-)?cross-fade|element|src)";
    private static readonly Regex CssLoadingCall = R(@"(?<![\w-])" + CssLoadingNames + """\s*\((?:"[^"]*"|'[^']*'|[^)"'])*\)""");
    private static readonly Regex CssLoadingFunction = R(CssLoadingNames + @"\s*\(");
    private static readonly Regex CssImportKeyword = R(@"@import\b");

    private static string Transform(Regex re, string s, Func<Match, string> body, Func<string, string>? gap = null)
    {
        gap ??= x => x;
        var sb = new StringBuilder();
        var cursor = 0;
        foreach (Match m in re.Matches(s))
        {
            sb.Append(gap(s[cursor..m.Index]));
            sb.Append(body(m));
            cursor = m.Index + m.Length;
        }
        sb.Append(gap(s[cursor..]));
        return sb.ToString();
    }
}
