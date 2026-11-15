import Foundation

/// Strips everything that would make the WebKit-backed HTML importer
/// (`NSAttributedString(data:options: [.documentType: .html])`) reach the network
/// — images, frames, scripts, stylesheets, CSS `url(...)`/`@import`, `background=`,
/// meta refresh, `<base>` — before copied HTML is converted to rich text.
///
/// Regex-based and deliberately biased towards stripping: losing an image or a
/// bit of styling from a clipboard item is harmless, a request to a tracking
/// pixel on every copy is not. `<a href>` survives (an anchor does not load).
enum HTMLSanitizer {

    static func sanitize(_ data: Data) -> Data {
        Data(sanitize(String(decoding: data, as: UTF8.self)).utf8)
    }

    static func sanitize(_ html: String) -> String {
        var s = html
        // 1. Comments (incl. IE conditional comments, which can carry markup).
        s = replace(comments, in: s, with: "")
        s = replace(unterminatedComment, in: s, with: "")
        // 2. Elements dropped together with their content.
        s = replace(droppedContainers, in: s, with: "")
        // 3. <style> blocks are kept (they carry the formatting) but their CSS is cleaned.
        s = transform(styleBlocks, in: s) { match, ns in
            let open = ns.substring(with: match.range(at: 1))
            let css = ns.substring(with: match.range(at: 2))
            let close = ns.substring(with: match.range(at: 3))
            return open + sanitizeCSS(css) + close
        }
        // 4. Every remaining tag: drop loading elements, rebuild the rest
        //    without their loading attributes. A `<` that starts a tag the pattern
        //    could not parse (an unbalanced quote, say) is escaped to text in the
        //    gaps between matches, so nothing unparsed reaches the importer as markup.
        s = transform(tags, in: s, gap: { replace(unparsedTagStart, in: $0, with: "&lt;") }) { match, ns in
            sanitizeTag(match, in: ns)
        }
        return s
    }

    // MARK: - Tags

    /// Elements whose tags are removed wherever they appear (their content, if any,
    /// was already removed in step 2 when properly closed).
    private static let droppedTagNames: Set<String> = [
        "img", "image", "picture", "source", "video", "audio", "track", "iframe", "frame",
        "frameset", "object", "embed", "applet", "param", "script", "link", "base", "svg",
        "use", "math", "noscript", "template", "portal", "fencedframe"
    ]

    /// Attributes that load (or can load) a resource, on any element.
    private static let droppedAttributes: Set<String> = [
        "src", "srcset", "imagesrcset", "srcdoc", "data", "background", "poster", "lowsrc",
        "dynsrc", "longdesc", "codebase", "archive", "classid", "formaction", "action",
        "xlink:href", "icon", "manifest", "ping", "content", "attributionsrc"
    ]

    /// Elements allowed to keep `href`.
    private static let hrefAllowedTags: Set<String> = ["a", "area"]

    private static func sanitizeTag(_ match: NSTextCheckingResult, in ns: NSString) -> String {
        let isClosing = match.range(at: 1).length > 0
        let name = ns.substring(with: match.range(at: 2))
        let lower = name.lowercased()
        if droppedTagNames.contains(lower) { return "" }
        if isClosing { return "</\(name)>" }

        let attrs = ns.substring(with: match.range(at: 3))
        if lower == "meta", attrs.range(of: "http-equiv", options: .caseInsensitive) != nil {
            return ""
        }

        var kept: [String] = []
        let attrsNS = attrs as NSString
        for attr in attribute.matches(in: attrs, range: NSRange(location: 0, length: attrsNS.length)) {
            let attrName = attrsNS.substring(with: attr.range(at: 1)).lowercased()
            if droppedAttributes.contains(attrName) || attrName.hasPrefix("on") { continue }
            if attrName == "href", !hrefAllowedTags.contains(lower) { continue }
            if attrName == "style" {
                guard attr.range(at: 2).location != NSNotFound else { continue }
                let raw = attrsNS.substring(with: attr.range(at: 2))
                let value = unquote(raw)
                // Attribute values are entity-decoded and CSS-unescaped by the
                // parser, so `u&#114;l(` or `u\72 l(` would slip past a textual
                // check — drop such a style outright instead of decoding it.
                if value.contains("&") || value.contains("\\") { continue }
                let clean = sanitizeCSS(value).replacingOccurrences(of: "\"", with: "'")
                kept.append("style=\"\(clean)\"")
                continue
            }
            kept.append(attrsNS.substring(with: attr.range))
        }
        let selfClosing = attrs.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
        let body = kept.isEmpty ? "" : " " + kept.joined(separator: " ")
        return "<\(name)\(body)\(selfClosing ? " /" : "")>"
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'",
              value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }

    // MARK: - CSS

    /// Removes `@import`, `url(...)` and the other CSS functions that can take a
    /// bare string URL. CSS escapes are decoded first so `\75 rl(` can't hide one.
    static func sanitizeCSS(_ css: String) -> String {
        var s = unescapeCSS(css)
        s = replace(cssComments, in: s, with: "")
        s = replace(cssImport, in: s, with: "")
        s = replace(cssURL, in: s, with: "none")
        s = replace(cssLoadingCall, in: s, with: "none")
        // Anything still shaped like a loading function (unbalanced url(, image-set("…"),
        // a leftover @import) is defused rather than parsed.
        s = replace(cssLoadingFunction, in: s, with: "x-blocked(")
        s = replace(cssImportKeyword, in: s, with: "@x-blocked")
        return s
    }

    private static func unescapeCSS(_ css: String) -> String {
        guard css.contains("\\") else { return css }
        return transform(cssEscape, in: css) { match, ns in
            if match.range(at: 1).location != NSNotFound,
               let code = UInt32(ns.substring(with: match.range(at: 1)), radix: 16),
               let scalar = Unicode.Scalar(code), code != 0 {
                return String(Character(scalar))
            }
            if match.range(at: 2).location != NSNotFound {
                return ns.substring(with: match.range(at: 2))
            }
            return ""
        }
    }

    // MARK: - Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Attribute values: double-quoted, single-quoted or unquoted.
    private static let attrChars = #"(?:[^>"']|"[^"]*"|'[^']*')*"#

    private static let comments = regex(#"<!--[\s\S]*?-->"#)
    private static let unterminatedComment = regex(#"<!--[\s\S]*$"#)
    private static let droppedContainers = regex(
        #"<(script|iframe|object|video|audio|picture|svg|math|noscript|template|frameset|applet|noembed|noframes)\b"#
            + attrChars + #">[\s\S]*?</\1\s*>"#)
    private static let styleBlocks = regex(#"(<style\b"# + attrChars + #">)([\s\S]*?)(</style\s*>|$)"#)
    private static let tags = regex(#"<(/?)([a-z][a-z0-9:_-]*)("# + attrChars + #")>"#)
    private static let unparsedTagStart = regex(#"<(?=/?[a-z])"#)
    private static let attribute = regex(#"([^\s"'>/=]+)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s"'>]+))?"#)

    private static let cssEscape = regex(#"\\(?:([0-9a-f]{1,6})\s?|(.)|$)"#)
    private static let cssComments = regex(#"/\*[\s\S]*?(?:\*/|$)"#)
    private static let cssImport = regex(#"@import\b[^;]*;?"#)
    private static let cssURL = regex(#"url\s*\(\s*(?:"[^"]*"|'[^']*'|[^)]*)\s*\)"#)
    /// CSS functions that take a URL or a bare string naming one.
    private static let cssLoadingNames = #"(?:url|(?:-webkit-)?image-set|image|(?:-webkit-)?cross-fade|element|src)"#
    private static let cssLoadingCall = regex(
        #"(?<![\w-])"# + cssLoadingNames + #"\s*\((?:"[^"]*"|'[^']*'|[^)"'])*\)"#)
    private static let cssLoadingFunction = regex(cssLoadingNames + #"\s*\("#)
    private static let cssImportKeyword = regex(#"@import\b"#)

    // MARK: - Regex helpers

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                    withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    /// Rebuilds `s` with every match replaced by `body`; the text between matches
    /// goes through `gap` (unchanged by default).
    private static func transform(_ re: NSRegularExpression, in s: String,
                                  gap: (String) -> String = { $0 },
                                  _ body: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for match in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += gap(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            out += body(match, ns)
            cursor = match.range.location + match.range.length
        }
        out += gap(ns.substring(from: cursor))
        return out
    }
}
