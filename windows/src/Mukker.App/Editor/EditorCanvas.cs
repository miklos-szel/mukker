using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Mukker.App.Editor;

/// <summary>
/// Draws the base image and every annotation into one surface. Units are capture pixels; the element's
/// own origin is <see cref="Origin"/> in canvas space (the canvas grows when annotations extend past the image).
/// The non-exported surround is a checkerboard on screen and white in the export.
/// </summary>
public sealed class EditorCanvas : FrameworkElement
{
    public EditorModel Model { get; }
    public Annotation? Draft { get; set; }
    public Rect? CropRect { get; set; }
    public Annotation? Selected { get; set; }
    public double Zoom { get; set; } = 1;

    /// <summary>Committed layout bounds (canvas space). Not updated mid-gesture so the canvas doesn't shift under the pointer.</summary>
    public Rect LayoutBounds { get; private set; }

    public Point Origin => LayoutBounds.TopLeft;

    private readonly Dictionary<Annotation, (int Version, ImageSource Image)> _blurCache = new();

    public EditorCanvas(EditorModel model)
    {
        Model = model;
        RecomputeLayout();
        SnapsToDevicePixels = true;
    }

    public void RecomputeLayout()
    {
        LayoutBounds = Model.ContentBounds(null);
        Width = LayoutBounds.Width;
        Height = LayoutBounds.Height;
        InvalidateVisual();
    }

    public Point ToCanvas(Point elementPoint) => elementPoint + (Vector)Origin;

    protected override void OnRender(DrawingContext dc)
    {
        dc.PushTransform(new TranslateTransform(-Origin.X, -Origin.Y));
        DrawCheckerboard(dc, LayoutBounds, Model.ImageRect);
        Render(dc, Model, Draft, _blurCache, export: false);

        if (Selected != null && Model.Annotations.Contains(Selected)) DrawSelection(dc, Selected);
        if (CropRect is { } crop) DrawCrop(dc, crop);
        dc.Pop();
    }

    /// <summary>Renders the image and annotations (and an optional draft) — shared by screen and export.</summary>
    public static void Render(DrawingContext dc, EditorModel model, Annotation? draft, Dictionary<Annotation, (int, ImageSource)>? cache, bool export)
    {
        dc.DrawImage(model.BaseImage, model.ImageRect);
        var list = draft == null ? model.Annotations : model.Annotations.Append(draft).ToList();
        for (var i = 0; i < list.Count; i++)
        {
            var a = list[i];
            if (a.Kind == Tool.Blur)
                DrawBlur(dc, model, list, i, cache);
            else
                DrawAnnotation(dc, a);
        }
    }

    private static void DrawCheckerboard(DrawingContext dc, Rect bounds, Rect image)
    {
        var outside = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(bounds), new RectangleGeometry(image));
        var tile = new DrawingBrush
        {
            TileMode = TileMode.Tile, Viewport = new Rect(0, 0, 16, 16), ViewportUnits = BrushMappingMode.Absolute,
            Drawing = new GeometryDrawing(new SolidColorBrush(Color.FromRgb(0xE4, 0xE4, 0xE7)), null,
                new GeometryGroup { Children = { new RectangleGeometry(new Rect(0, 0, 8, 8)), new RectangleGeometry(new Rect(8, 8, 8, 8)) } }),
        };
        dc.DrawGeometry(Brushes.White, null, outside);
        dc.DrawGeometry(tile, null, outside);
    }

    public static void DrawAnnotation(DrawingContext dc, Annotation a)
    {
        var brush = new SolidColorBrush(a.Color);
        var pen = new Pen(brush, a.LineWidth) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        switch (a.Kind)
        {
            case Tool.Line:
                dc.DrawLine(pen, a.Start, a.End);
                break;
            case Tool.Arrow:
                DrawArrow(dc, a, brush, pen);
                break;
            case Tool.Rectangle:
                dc.DrawRectangle(null, pen, a.Rect);
                break;
            case Tool.RoundedRectangle:
                var r = Math.Min(Annotation.CornerRadius, Math.Min(a.Rect.Width, a.Rect.Height) / 2);
                dc.DrawRoundedRectangle(null, pen, a.Rect, r, r);
                break;
            case Tool.Ellipse:
                var rect = a.Rect;
                dc.DrawEllipse(null, pen, new Point(rect.X + rect.Width / 2, rect.Y + rect.Height / 2), rect.Width / 2, rect.Height / 2);
                break;
            case Tool.Highlight:
                dc.DrawRectangle(new SolidColorBrush(Color.FromArgb((byte)(255 * 0.35), a.Color.R, a.Color.G, a.Color.B)), null, a.Rect);
                break;
            case Tool.Pen:
                if (a.Points.Count < 2)
                {
                    if (a.Points.Count == 1) dc.DrawEllipse(brush, null, a.Points[0], a.LineWidth / 2, a.LineWidth / 2);
                    break;
                }
                var geo = new StreamGeometry();
                using (var ctx = geo.Open())
                {
                    ctx.BeginFigure(a.Points[0], false, false);
                    ctx.PolyLineTo(a.Points.Skip(1).ToList(), true, true);
                }
                geo.Freeze();
                dc.DrawGeometry(null, pen, geo);
                break;
            case Tool.Text:
                var ft = a.FormatText();
                var box = new Rect(a.Start, new Size(ft.WidthIncludingTrailingWhitespace + 2 * Annotation.TextPadding, ft.Height + 2 * Annotation.TextPadding));
                if (a.TextBackground) dc.DrawRoundedRectangle(brush, null, box, 5, 5);
                dc.DrawText(ft, new Point(a.Start.X + Annotation.TextPadding, a.Start.Y + Annotation.TextPadding));
                break;
            case Tool.Counter:
                var d = Math.Max(Annotation.CounterDiameter, a.LineWidth * 6);
                dc.DrawEllipse(brush, new Pen(Brushes.White, 2), a.Start, d / 2, d / 2);
                var num = new FormattedText(a.Number.ToString(), System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                    Annotation.TextFace, d * 0.5, IsLight(a.Color) ? Brushes.Black : Brushes.White, 1.0);
                dc.DrawText(num, new Point(a.Start.X - num.Width / 2, a.Start.Y - num.Height / 2));
                break;
        }
    }

    private static bool IsLight(Color c) => c.R * 0.299 + c.G * 0.587 + c.B * 0.114 > 186;

    private static void DrawArrow(DrawingContext dc, Annotation a, Brush brush, Pen pen)
    {
        var v = a.End - a.Start;
        var len = v.Length;
        if (len < 1) return;
        v /= len;
        var headLen = Math.Max(12, a.LineWidth * 4.5);
        var headW = headLen * 0.6;
        var baseP = a.End - v * Math.Min(headLen, len);
        var n = new Vector(-v.Y, v.X);
        dc.DrawLine(pen, a.Start, baseP + v * 1); // stop under the head
        var head = new StreamGeometry();
        using (var ctx = head.Open())
        {
            ctx.BeginFigure(a.End, true, true);
            ctx.LineTo(baseP + n * headW, true, true);
            ctx.LineTo(baseP - n * headW, true, true);
        }
        head.Freeze();
        dc.DrawGeometry(brush, new Pen(brush, 1) { LineJoin = PenLineJoin.Round }, head);
    }

    /// <summary>
    /// Pixelates the composite beneath the blur rect — the image and every annotation drawn before it —
    /// so the blur also hides annotations under it, like the Mac editor.
    /// </summary>
    private static void DrawBlur(DrawingContext dc, EditorModel model, IReadOnlyList<Annotation> list, int index, Dictionary<Annotation, (int, ImageSource)>? cache)
    {
        var a = list[index];
        var rect = a.Rect;
        rect.Intersect(model.ContentBounds(null));
        if (rect.IsEmpty || rect.Width < 1 || rect.Height < 1) return;
        var block = Math.Clamp(Math.Min(rect.Width, rect.Height) * 0.08, 6, 25);
        var key = HashCode.Combine(model.Version, index, rect, block);
        if (cache != null && cache.TryGetValue(a, out var hit) && hit.Item1 == key)
        {
            DrawPixelated(dc, hit.Item2, rect);
            return;
        }
        var w = Math.Max(1, (int)Math.Ceiling(rect.Width / block));
        var h = Math.Max(1, (int)Math.Ceiling(rect.Height / block));
        var visual = new DrawingVisual();
        using (var inner = visual.RenderOpen())
        {
            inner.PushTransform(new ScaleTransform(w / rect.Width, h / rect.Height));
            inner.PushTransform(new TranslateTransform(-rect.X, -rect.Y));
            inner.DrawRectangle(Brushes.White, null, rect);
            inner.DrawImage(model.BaseImage, model.ImageRect);
            for (var i = 0; i < index; i++)
                if (list[i].Kind != Tool.Blur) DrawAnnotation(inner, list[i]);
            inner.Pop();
            inner.Pop();
        }
        var rtb = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(visual);
        rtb.Freeze();
        if (cache != null) cache[a] = (key, rtb);
        DrawPixelated(dc, rtb, rect);
    }

    private static void DrawPixelated(DrawingContext dc, ImageSource small, Rect rect)
    {
        var group = new DrawingGroup();
        RenderOptions.SetBitmapScalingMode(group, BitmapScalingMode.NearestNeighbor);
        using (var g = group.Open()) g.DrawImage(small, rect);
        dc.DrawDrawing(group);
    }

    private void DrawSelection(DrawingContext dc, Annotation a)
    {
        var pen = new Pen(new SolidColorBrush(Color.FromRgb(0x2F, 0x6F, 0xEB)), 1 / Zoom) { DashStyle = DashStyles.Dash };
        dc.DrawRectangle(null, pen, a.Bounds);
        if (ToolInfo.IsTwoPoint(a.Kind))
            foreach (var p in new[] { a.Start, a.End }) DrawHandle(dc, p);
    }

    public double HandleRadius => 5 / Zoom;

    private void DrawHandle(DrawingContext dc, Point p) =>
        dc.DrawEllipse(Brushes.White, new Pen(new SolidColorBrush(Color.FromRgb(0x2F, 0x6F, 0xEB)), 1.5 / Zoom), p, HandleRadius, HandleRadius);

    private void DrawCrop(DrawingContext dc, Rect crop)
    {
        var outside = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(LayoutBounds), new RectangleGeometry(crop));
        dc.DrawGeometry(new SolidColorBrush(Color.FromArgb(0x88, 0, 0, 0)), null, outside);
        dc.DrawRectangle(null, new Pen(Brushes.White, 1.5 / Zoom) { DashStyle = DashStyles.Dash }, crop);
    }
}

/// <summary>The editor document: the base image (a movable layer), the ordered annotations and undo history.</summary>
public sealed class EditorModel
{
    public BitmapSource BaseImage { get; private set; }
    public Point ImageOrigin { get; set; }
    public List<Annotation> Annotations { get; private set; } = new();
    public double CaptureScale { get; }
    /// <summary>Bumped on every committed change; keys the blur cache.</summary>
    public int Version { get; private set; }

    private readonly Stack<Snapshot> _undo = new();
    private readonly Stack<Snapshot> _redo = new();
    private const int MaxUndo = 50;

    private sealed record Snapshot(BitmapSource Image, Point Origin, List<Annotation> Annotations);

    public EditorModel(BitmapSource image, double captureScale)
    {
        BaseImage = image;
        CaptureScale = captureScale;
    }

    public Rect ImageRect => new(ImageOrigin, new Size(BaseImage.PixelWidth, BaseImage.PixelHeight));

    /// <summary>Image ∪ annotations (∪ draft) — what is drawn and exported.</summary>
    public Rect ContentBounds(Annotation? draft)
    {
        var r = ImageRect;
        foreach (var a in Annotations) if (!a.Bounds.IsEmpty) r.Union(a.Bounds);
        if (draft != null && !draft.Bounds.IsEmpty) r.Union(draft.Bounds);
        return new Rect(Math.Floor(r.X), Math.Floor(r.Y), Math.Ceiling(r.Width), Math.Ceiling(r.Height));
    }

    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;

    private Snapshot Take() => new(BaseImage, ImageOrigin, Annotations.Select(a => a.Clone()).ToList());

    /// <summary>Call before every mutation.</summary>
    public void Checkpoint()
    {
        _undo.Push(Take());
        if (_undo.Count > MaxUndo)
        {
            var keep = _undo.Take(MaxUndo).Reverse().ToList();
            _undo.Clear();
            foreach (var s in keep) _undo.Push(s);
        }
        _redo.Clear();
    }

    public void Changed() => Version++;

    public void Undo() => Swap(_undo, _redo);
    public void Redo() => Swap(_redo, _undo);

    private void Swap(Stack<Snapshot> from, Stack<Snapshot> to)
    {
        if (from.Count == 0) return;
        to.Push(Take());
        var s = from.Pop();
        BaseImage = s.Image;
        ImageOrigin = s.Origin;
        Annotations = s.Annotations;
        Version++;
    }

    public int NextCounter() => Annotations.Where(a => a.Kind == Tool.Counter).Select(a => a.Number).DefaultIfEmpty(0).Max() + 1;

    /// <summary>Flattens image + annotations to a bitmap at capture scale, white where nothing was drawn.</summary>
    public BitmapSource Flatten(Rect? area = null)
    {
        var bounds = area ?? ContentBounds(null);
        var w = Math.Max(1, (int)Math.Round(bounds.Width));
        var h = Math.Max(1, (int)Math.Round(bounds.Height));
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.PushTransform(new TranslateTransform(-bounds.X, -bounds.Y));
            dc.DrawRectangle(Brushes.White, null, bounds);
            EditorCanvas.Render(dc, this, null, null, export: true);
            dc.Pop();
        }
        var rtb = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(visual);
        rtb.Freeze();
        return rtb;
    }

    /// <summary>Crop: everything inside the rect becomes the new base image.</summary>
    public void ApplyCrop(Rect crop)
    {
        var bounds = ContentBounds(null);
        crop.Intersect(bounds);
        if (crop.IsEmpty || crop.Width < 2 || crop.Height < 2) return;
        Checkpoint();
        BaseImage = Flatten(new Rect(Math.Round(crop.X), Math.Round(crop.Y), Math.Round(crop.Width), Math.Round(crop.Height)));
        ImageOrigin = new Point(0, 0);
        Annotations = new List<Annotation>();
        Changed();
    }
}
