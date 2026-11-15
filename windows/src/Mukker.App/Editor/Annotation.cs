using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Media;

namespace Mukker.App.Editor;

/// <summary>Editor tools. Non-drawing tools (select, hand, crop) have no annotation kind.</summary>
public enum Tool { Select, Hand, Arrow, Line, Rectangle, RoundedRectangle, Ellipse, Pen, Text, Counter, Highlight, Blur, Crop }

public static class ToolInfo
{
    public static readonly IReadOnlyDictionary<Tool, char> DefaultKeys = new Dictionary<Tool, char>
    {
        [Tool.Select] = 'v', [Tool.Hand] = 'm', [Tool.Arrow] = 'a', [Tool.Line] = 'l', [Tool.Rectangle] = 'o',
        [Tool.RoundedRectangle] = 'r', [Tool.Ellipse] = 'e', [Tool.Pen] = 'p', [Tool.Text] = 't', [Tool.Counter] = 'n',
        [Tool.Highlight] = 'h', [Tool.Blur] = 'b', [Tool.Crop] = 'c',
    };

    public static string Name(Tool t) => t switch
    {
        Tool.Select => "Select",
        Tool.Hand => "Hand",
        Tool.Arrow => "Arrow",
        Tool.Line => "Line",
        Tool.Rectangle => "Rectangle",
        Tool.RoundedRectangle => "Rounded Rectangle",
        Tool.Ellipse => "Ellipse",
        Tool.Pen => "Pen",
        Tool.Text => "Text",
        Tool.Counter => "Counter",
        Tool.Highlight => "Highlight",
        Tool.Blur => "Blur",
        _ => "Crop",
    };

    public static bool Draws(Tool t) => t is not (Tool.Select or Tool.Hand or Tool.Crop);

    public static bool IsTwoPoint(Tool t) => t is Tool.Arrow or Tool.Line or Tool.Rectangle or Tool.RoundedRectangle
        or Tool.Ellipse or Tool.Highlight or Tool.Blur;

    /// <summary>Resolves the key for each tool, applying user overrides (a key assigned to two tools swaps them).</summary>
    public static Dictionary<Tool, char> Keys(IReadOnlyDictionary<string, string> overrides)
    {
        var keys = DefaultKeys.ToDictionary(kv => kv.Key, kv => kv.Value);
        foreach (var (name, key) in overrides)
        {
            if (!Enum.TryParse<Tool>(name, true, out var tool) || string.IsNullOrEmpty(key)) continue;
            var k = char.ToLowerInvariant(key[0]);
            var other = keys.Where(kv => kv.Value == k && kv.Key != tool).Select(kv => (Tool?)kv.Key).FirstOrDefault();
            if (other is { } o) keys[o] = keys[tool]; // the tool that had this key takes over the old one
            keys[tool] = k;
        }
        return keys;
    }
}

public static class Palette
{
    public static readonly (string Name, Color Color)[] Colors =
    [
        ("Red", Color.FromRgb(0xF2, 0x3B, 0x30)),
        ("Orange", Color.FromRgb(0xFF, 0x95, 0x00)),
        ("Yellow", Color.FromRgb(0xFF, 0xCC, 0x00)),
        ("Green", Color.FromRgb(0x34, 0xC7, 0x59)),
        ("Blue", Color.FromRgb(0x0A, 0x84, 0xFF)),
        ("Purple", Color.FromRgb(0xAF, 0x52, 0xDE)),
        ("Black", Color.FromRgb(0x1C, 0x1C, 0x1E)),
        ("White", Color.FromRgb(0xFF, 0xFF, 0xFF)),
    ];

    public static Color At(int i) => Colors[Math.Clamp(i, 0, Colors.Length - 1)].Color;
}

/// <summary>One annotation, in canvas units (= capture pixels).</summary>
public sealed class Annotation
{
    public Tool Kind { get; set; }
    public Point Start { get; set; }
    public Point End { get; set; }
    public List<Point> Points { get; set; } = new();
    public Color Color { get; set; }
    public double LineWidth { get; set; } = 2;
    public string Text { get; set; } = "";
    public double FontSize { get; set; } = 14;
    public Color TextColor { get; set; } = Colors.White;
    public bool TextBackground { get; set; } = true;
    public int Number { get; set; }

    public const double CornerRadius = 12;
    public const double CounterDiameter = 30;

    public Annotation Clone() => new()
    {
        Kind = Kind, Start = Start, End = End, Points = new List<Point>(Points), Color = Color, LineWidth = LineWidth,
        Text = Text, FontSize = FontSize, TextColor = TextColor, TextBackground = TextBackground, Number = Number,
    };

    public Rect Rect => new(Start, End);

    public void Offset(Vector v)
    {
        Start += v;
        End += v;
        for (var i = 0; i < Points.Count; i++) Points[i] += v;
    }

    public static Typeface TextFace => new(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);

    public FormattedText FormatText(double pixelsPerDip = 1.0)
    {
        var t = string.IsNullOrEmpty(Text) ? " " : Text;
        return new FormattedText(t, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, TextFace, FontSize, new SolidColorBrush(TextColor), pixelsPerDip);
    }

    public const double TextPadding = 6;

    /// <summary>Bounds including stroke width, for hit testing, canvas growth and selection.</summary>
    public Rect Bounds
    {
        get
        {
            Rect r;
            switch (Kind)
            {
                case Tool.Pen:
                    if (Points.Count == 0) return Rect.Empty;
                    r = new Rect(Points[0], Points[0]);
                    foreach (var p in Points) r.Union(p);
                    break;
                case Tool.Text:
                    var ft = FormatText();
                    r = new Rect(Start, new Size(ft.WidthIncludingTrailingWhitespace + 2 * TextPadding, ft.Height + 2 * TextPadding));
                    return r;
                case Tool.Counter:
                    var d = Math.Max(CounterDiameter, LineWidth * 6);
                    return new Rect(Start.X - d / 2, Start.Y - d / 2, d, d);
                default:
                    r = Rect;
                    break;
            }
            var pad = Kind == Tool.Arrow ? LineWidth * 4 + 6 : LineWidth / 2 + 1;
            r.Inflate(pad, pad);
            return r;
        }
    }

    public bool HitTest(Point p, double tolerance)
    {
        switch (Kind)
        {
            case Tool.Line:
            case Tool.Arrow:
                return DistanceToSegment(p, Start, End) <= tolerance + LineWidth / 2;
            case Tool.Pen:
                for (var i = 1; i < Points.Count; i++)
                    if (DistanceToSegment(p, Points[i - 1], Points[i]) <= tolerance + LineWidth / 2) return true;
                return false;
            case Tool.Rectangle:
            case Tool.RoundedRectangle:
            case Tool.Ellipse:
                var outer = Rect;
                outer.Inflate(tolerance + LineWidth, tolerance + LineWidth);
                var inner = Rect;
                inner.Inflate(-(tolerance + LineWidth), -(tolerance + LineWidth));
                return outer.Contains(p) && (inner.IsEmpty || !inner.Contains(p));
            default:
                return Bounds.Contains(p);
        }
    }

    private static double DistanceToSegment(Point p, Point a, Point b)
    {
        var ab = b - a;
        var len = ab.LengthSquared;
        if (len < 1e-6) return (p - a).Length;
        var t = Math.Clamp(Vector.Multiply(p - a, ab) / len, 0, 1);
        return (p - (a + t * ab)).Length;
    }
}
