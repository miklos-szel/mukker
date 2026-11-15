using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Mukker.App.Capture;
using Mukker.Core.Settings;

namespace Mukker.App.Editor;

/// <summary>
/// The annotation editor. Annotations are value objects on <see cref="EditorModel"/>; the canvas draws them;
/// this window turns pointer and key input into model changes.
/// </summary>
public sealed class EditorWindow : Window
{
    private readonly AppHost _host;
    private readonly EditorModel _model;
    private readonly EditorCanvas _canvas;
    private readonly Canvas _overlay = new();         // hosts the inline text box
    private readonly Grid _surface = new();
    private readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Background = new SolidColorBrush(Color.FromRgb(0xEE, 0xEE, 0xF0)), Focusable = false };
    private readonly ScaleTransform _zoom = new(1, 1);
    private readonly Dictionary<Tool, ToggleButton> _toolButtons = new();
    private readonly List<Border> _swatches = new();
    private readonly Slider _width = new() { Minimum = 1, Maximum = 20, Width = 90, IsSnapToTickEnabled = true, TickFrequency = 1, VerticalAlignment = VerticalAlignment.Center, Focusable = false };
    private readonly Slider _textSize = new() { Minimum = 10, Maximum = 96, Width = 90, IsSnapToTickEnabled = true, TickFrequency = 1, VerticalAlignment = VerticalAlignment.Center, Focusable = false };
    private readonly ToggleButton _textBg = new() { Content = "Aa", ToolTip = "Text background", FontWeight = FontWeights.Bold };
    private readonly TextBlock _zoomLabel = new() { VerticalAlignment = VerticalAlignment.Center, Width = 44, TextAlignment = TextAlignment.Right, Foreground = Brushes.DimGray };
    private readonly TextBlock _flash = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0), Foreground = Brushes.DimGray };
    private readonly Button _undo = new(), _redo = new();

    private Tool _tool = Tool.Arrow;
    private int _colorIndex;
    private Dictionary<Tool, char> _keys;

    // Gesture state
    private Point _down;
    private bool _dragging;
    private enum Drag { None, Draw, Move, Handle, Image, Pan, Crop }
    private Drag _drag;
    private int _handleIndex;
    private Point _panStart;
    private Point _panOffset;
    private Annotation? _moving;
    private TextBox? _editor;
    private Annotation? _editingText;

    private CaptureSettings Settings => _host.Settings.Current.Capture;

    internal static EditorWindow Open(AppHost host, CaptureResult capture)
    {
        var w = new EditorWindow(host, new EditorModel(capture.Image, capture.Scale));
        w.Show();
        w.Activate();
        return w;
    }

    /// <summary>A sample canvas for the MUKKER_OPEN=editor debug hook.</summary>
    internal static void OpenSample(AppHost host)
    {
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.DrawRectangle(new LinearGradientBrush(Color.FromRgb(0x2B, 0x5D, 0xB8), Color.FromRgb(0xE6, 0x97, 0x18), 30), null, new Rect(0, 0, 900, 560));
            var ft = new FormattedText("Mukker sample capture", System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                new Typeface("Segoe UI"), 44, Brushes.White, 1.0);
            dc.DrawText(ft, new Point(60, 60));
        }
        var rtb = new RenderTargetBitmap(900, 560, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(visual);
        rtb.Freeze();
        Open(host, new CaptureResult(rtb, 1));
    }

    private EditorWindow(AppHost host, EditorModel model)
    {
        _host = host;
        _model = model;
        _canvas = new EditorCanvas(model);
        _keys = ToolInfo.Keys(Settings.ToolShortcuts);
        _colorIndex = Math.Clamp(Settings.DefaultColorIndex, 0, Palette.Colors.Length - 1);
        _width.Value = Math.Clamp(Settings.DefaultLineWidth, 1, 20);
        _textSize.Value = Math.Clamp(Settings.DefaultTextSize, 10, 96);
        _textBg.IsChecked = true;

        Title = $"Mukker — Capture {model.BaseImage.PixelWidth}×{model.BaseImage.PixelHeight}";
        MinWidth = 640;
        MinHeight = 420;
        Background = (Brush)FindResource("Surface");
        Icon = BitmapFrame.Create(new Uri("pack://application:,,,/Mukker;component/Assets/mukker.ico"));

        var root = new DockPanel();
        var toolbar = BuildToolbar();
        DockPanel.SetDock(toolbar, Dock.Top);
        root.Children.Add(toolbar);

        _surface.LayoutTransform = _zoom;
        _surface.HorizontalAlignment = HorizontalAlignment.Center;
        _surface.VerticalAlignment = VerticalAlignment.Center;
        _surface.Margin = new Thickness(Settings.CanvasPadding);
        _surface.Children.Add(_canvas);
        _surface.Children.Add(_overlay);
        _surface.Background = Brushes.Transparent;
        RenderOptions.SetBitmapScalingMode(_canvas, BitmapScalingMode.HighQuality);
        _scroll.Content = _surface;
        root.Children.Add(_scroll);
        Content = root;

        _surface.MouseLeftButtonDown += OnDown;
        _surface.MouseMove += OnMove;
        _surface.MouseLeftButtonUp += OnUp;
        _scroll.PreviewMouseWheel += OnWheel;
        PreviewKeyDown += OnKey;
        Loaded += (_, _) =>
        {
            SizeToImage();
            Keyboard.Focus(this);
            // Fit once the resized window and the (possibly wrapped) toolbar have been laid out.
            Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () => FitZoom(initial: true));
        };
        SetTool(Tool.Arrow);
        SelectColor(_colorIndex);
        RefreshUndo();
    }

    // MARK: - Toolbar

    private static Geometry G(string data) => Geometry.Parse(data);

    private static readonly Dictionary<Tool, (string Data, bool Fill)> Icons = new()
    {
        [Tool.Select] = ("M5,2 L5,17 L9,13 L12,19 L14,18 L11,12 L16,12 Z", true),
        [Tool.Hand] = ("M10,1 L13,4 L11,4 L11,9 L16,9 L16,7 L19,10 L16,13 L16,11 L11,11 L11,16 L13,16 L10,19 L7,16 L9,16 L9,11 L4,11 L4,13 L1,10 L4,7 L4,9 L9,9 L9,4 L7,4 Z", true),
        [Tool.Arrow] = ("M3,17 L15,5 M8,5 L15,5 L15,12", false),
        [Tool.Line] = ("M3,17 L17,3", false),
        [Tool.Rectangle] = ("M3,5 L17,5 L17,15 L3,15 Z", false),
        [Tool.RoundedRectangle] = ("M6,5 L14,5 A3,3 0 0 1 17,8 L17,12 A3,3 0 0 1 14,15 L6,15 A3,3 0 0 1 3,12 L3,8 A3,3 0 0 1 6,5 Z", false),
        [Tool.Ellipse] = ("M3,10 A7,5 0 1 1 17,10 A7,5 0 1 1 3,10 Z", false),
        [Tool.Pen] = ("M3,15 C6,4 9,18 12,8 S16,6 17,4", false),
        [Tool.Text] = ("M4,4 L16,4 M10,4 L10,17 M7,17 L13,17", false),
        [Tool.Counter] = ("M10,2 A8,8 0 1 1 9.99,2 Z M9,6 L11,5 L11,15 M8.5,15 L13,15", false),
        [Tool.Highlight] = ("M2,7 L18,7 L18,13 L2,13 Z", true),
        [Tool.Blur] = ("M3,3 h4 v4 h-4 Z M11,3 h4 v4 h-4 Z M7,7 h4 v4 h-4 Z M15,7 h2 v4 h-2 Z M3,11 h4 v4 h-4 Z M11,11 h4 v4 h-4 Z M7,15 h4 v2 h-4 Z", true),
        [Tool.Crop] = ("M6,1 L6,14 L19,14 M1,6 L14,6 L14,19", false),
    };

    /// <summary>
    /// Primary actions (Copy, Save, Undo, Redo, zoom) sit first on the left so they are never pushed
    /// off-screen; tools and style controls follow in groups that wrap onto a second row when narrow.
    /// </summary>
    private FrameworkElement BuildToolbar()
    {
        var bar = new Grid { Background = (Brush)FindResource("SurfaceAlt") };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 6, 4, 6), VerticalAlignment = VerticalAlignment.Top };
        var copy = new Button { Content = "Copy", ToolTip = "Copy (Ctrl+C / Enter)", Style = (Style)FindResource("AccentButton"), Height = 30, Margin = new Thickness(0, 0, 6, 0) };
        copy.Click += (_, _) => Copy();
        var save = new Button { Content = "Save", ToolTip = "Save (Ctrl+S)", Height = 30, Margin = new Thickness(0, 0, 6, 0) };
        save.Click += (_, _) => Save();
        _undo.Content = "\uE7A7"; _undo.Style = (Style)FindResource("IconButton"); _undo.ToolTip = "Undo (Ctrl+Z)"; _undo.Click += (_, _) => Undo();
        _redo.Content = "\uE7A6"; _redo.Style = (Style)FindResource("IconButton"); _redo.ToolTip = "Redo (Ctrl+Shift+Z)"; _redo.Click += (_, _) => Redo();
        var fit = new Button { Content = "\uE9A6", Style = (Style)FindResource("IconButton"), ToolTip = "Fit (Ctrl+0)" };
        fit.Click += (_, _) => FitZoom();
        actions.Children.Add(copy);
        actions.Children.Add(save);
        actions.Children.Add(_undo);
        actions.Children.Add(_redo);
        actions.Children.Add(fit);
        actions.Children.Add(_zoomLabel);
        actions.Children.Add(Separator());
        bar.Children.Add(actions);

        var wrap = new WrapPanel { Margin = new Thickness(0, 6, 8, 6) };
        Grid.SetColumn(wrap, 1);
        bar.Children.Add(wrap);

        StackPanel Group()
        {
            var g = new StackPanel { Orientation = Orientation.Horizontal, Height = 30, Margin = new Thickness(0, 0, 0, 2) };
            wrap.Children.Add(g);
            return g;
        }

        var tools = Group();
        foreach (var tool in Enum.GetValues<Tool>())
        {
            var (data, fill) = Icons[tool];
            var path = new Path
            {
                Data = G(data), Width = 20, Height = 20, Stretch = Stretch.None,
                Stroke = fill ? null : (Brush)FindResource("Ink"), StrokeThickness = 1.6,
                Fill = fill ? (tool == Tool.Highlight ? new SolidColorBrush(Color.FromArgb(0x90, 0xFF, 0xCC, 0x00)) : (Brush)FindResource("Ink")) : null,
                StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
            };
            var b = new ToggleButton { Content = path, Style = (Style)FindResource("ToolToggle") };
            var t = tool;
            b.Click += (_, _) => SetTool(t);
            _toolButtons[tool] = b;
            tools.Children.Add(b);
            if (tool is Tool.Hand or Tool.Pen or Tool.Blur) tools.Children.Add(Separator());
        }
        tools.Children.Add(Separator());

        var colors = Group();
        for (var i = 0; i < Palette.Colors.Length; i++)
        {
            var (name, color) = Palette.Colors[i];
            var sw = new Border
            {
                Width = 18, Height = 18, CornerRadius = new CornerRadius(9), Background = new SolidColorBrush(color),
                BorderBrush = Brushes.Gray, BorderThickness = new Thickness(1), Margin = new Thickness(2, 0, 2, 0), Cursor = Cursors.Hand, ToolTip = name,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var idx = i;
            sw.MouseLeftButtonUp += (_, _) => SelectColor(idx);
            _swatches.Add(sw);
            colors.Children.Add(sw);
        }
        colors.Children.Add(Separator());

        var style = Group();
        style.Children.Add(Caption("Width"));
        style.Children.Add(_width);
        style.Children.Add(Caption("Text"));
        style.Children.Add(_textSize);
        _textBg.Style = (Style)FindResource("ToolToggle");
        style.Children.Add(_textBg);
        style.Children.Add(_flash);
        _width.ValueChanged += (_, _) => ApplyStyleToSelection(a => a.LineWidth = _width.Value);
        _textSize.ValueChanged += (_, _) => ApplyStyleToSelection(a => { if (a.Kind == Tool.Text) a.FontSize = _textSize.Value; });
        _textBg.Click += (_, _) => ApplyStyleToSelection(a => { if (a.Kind == Tool.Text) a.TextBackground = _textBg.IsChecked == true; });
        return bar;
    }

    private static UIElement Separator() => new Rectangle { Width = 1, Height = 20, Fill = new SolidColorBrush(Color.FromRgb(0xD8, 0xD8, 0xDC)), Margin = new Thickness(6, 0, 6, 0) };

    private static UIElement Caption(string text) => new TextBlock { Text = text, Foreground = Brushes.DimGray, FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 4, 0) };

    private void SetTool(Tool tool)
    {
        CommitText();
        _tool = tool;
        foreach (var (t, b) in _toolButtons)
        {
            b.IsChecked = t == tool;
            b.ToolTip = $"{ToolInfo.Name(t)} ({char.ToUpperInvariant(_keys[t])})";
        }
        if (tool != Tool.Select) { _canvas.Selected = null; }
        if (tool != Tool.Crop) _canvas.CropRect = null;
        _surface.Cursor = tool switch
        {
            Tool.Hand => Cursors.SizeAll,
            Tool.Select => Cursors.Arrow,
            Tool.Text => Cursors.IBeam,
            _ => Cursors.Cross,
        };
        _canvas.InvalidateVisual();
    }

    private void SelectColor(int index)
    {
        _colorIndex = index;
        for (var i = 0; i < _swatches.Count; i++)
        {
            _swatches[i].BorderBrush = i == index ? (Brush)FindResource("Accent") : Brushes.Gray;
            _swatches[i].BorderThickness = new Thickness(i == index ? 3 : 1);
        }
        ApplyStyleToSelection(a => a.Color = Palette.At(index));
    }

    private void ApplyStyleToSelection(Action<Annotation> change)
    {
        if (_canvas.Selected is not { } sel || !_model.Annotations.Contains(sel)) return;
        _model.Checkpoint();
        change(sel);
        _model.Changed();
        Commit();
    }

    // MARK: - Zoom

    private void SizeToImage()
    {
        var work = SystemParameters.WorkArea;
        var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var w = _model.BaseImage.PixelWidth / dpi + 2 * Settings.CanvasPadding + 40;
        var h = _model.BaseImage.PixelHeight / dpi + 2 * Settings.CanvasPadding + 100;
        // At least wide enough for the toolbar on two rows, even for a small capture.
        Width = Math.Clamp(Math.Max(w, 980), MinWidth, work.Width * 0.95);
        Height = Math.Clamp(h, MinHeight, work.Height * 0.9);
        Left = work.Left + (work.Width - Width) / 2;
        Top = work.Top + (work.Height - Height) / 2;
    }

    private void SetZoom(double z)
    {
        z = Math.Clamp(z, 0.05, 16);
        _zoom.ScaleX = _zoom.ScaleY = z;
        _canvas.Zoom = z * VisualTreeHelper.GetDpi(this).DpiScaleX;
        _zoomLabel.Text = $"{Math.Round(_canvas.Zoom * 100)}%";
        _canvas.InvalidateVisual();
    }

    /// <summary>Fits the canvas in the window; on open never enlarges beyond 1 image pixel = 1 screen pixel.</summary>
    private void FitZoom(bool initial = false)
    {
        UpdateLayout();
        var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var availW = Math.Max(50, _scroll.ActualWidth - 2 * Settings.CanvasPadding - 4);
        var availH = Math.Max(50, _scroll.ActualHeight - 2 * Settings.CanvasPadding - 4);
        var fit = Math.Min(availW / _canvas.Width, availH / _canvas.Height);
        var actual = 1 / dpi;
        SetZoom(initial ? Math.Min(fit, actual) : fit);
    }

    private void OnWheel(object sender, MouseWheelEventArgs e)
    {
        e.Handled = true;
        var factor = e.Delta > 0 ? 1.1 : 1 / 1.1;
        SetZoom(_zoom.ScaleX * factor);
    }

    // MARK: - Pointer

    private Point CanvasPoint(MouseEventArgs e) => _canvas.ToCanvas(e.GetPosition(_canvas));

    private Annotation? HitAnnotation(Point p)
    {
        var tol = 4 / _canvas.Zoom;
        for (var i = _model.Annotations.Count - 1; i >= 0; i--)
            if (_model.Annotations[i].HitTest(p, tol)) return _model.Annotations[i];
        return null;
    }

    private void OnDown(object sender, MouseButtonEventArgs e)
    {
        Keyboard.Focus(this);
        if (_editor != null && !_editor.IsMouseOver) CommitText();
        var p = CanvasPoint(e);
        _down = p;
        _dragging = true;
        _surface.CaptureMouse();
        var color = Palette.At(_colorIndex);

        switch (_tool)
        {
            case Tool.Hand:
                _drag = Drag.Pan;
                _panStart = e.GetPosition(_scroll);
                _panOffset = new Point(_scroll.HorizontalOffset, _scroll.VerticalOffset);
                break;
            case Tool.Select:
                if (_canvas.Selected is { } sel && ToolInfo.IsTwoPoint(sel.Kind))
                {
                    var r = _canvas.HandleRadius * 2;
                    if ((p - sel.Start).Length <= r) { BeginHandle(sel, 0); return; }
                    if ((p - sel.End).Length <= r) { BeginHandle(sel, 1); return; }
                }
                var hit = HitAnnotation(p);
                if (e.ClickCount == 2 && hit is { Kind: Tool.Text })
                {
                    _dragging = false;
                    _surface.ReleaseMouseCapture();
                    BeginTextEdit(hit);
                    return;
                }
                _canvas.Selected = hit;
                if (hit != null)
                {
                    _model.Checkpoint();
                    _moving = hit;
                    _drag = Drag.Move;
                }
                else if (_model.ImageRect.Contains(p))
                {
                    _model.Checkpoint();
                    _drag = Drag.Image; // the base image is a movable layer
                }
                else _drag = Drag.None;
                _canvas.InvalidateVisual();
                break;
            case Tool.Crop:
                _drag = Drag.Crop;
                _canvas.CropRect = new Rect(p, p);
                break;
            case Tool.Text:
                _dragging = false;
                _surface.ReleaseMouseCapture();
                var hitText = HitAnnotation(p);
                if (hitText is { Kind: Tool.Text }) BeginTextEdit(hitText);
                else BeginTextEdit(new Annotation
                {
                    Kind = Tool.Text, Start = p, Color = color, TextColor = Palette.At(Settings.DefaultTextColorIndex),
                    FontSize = _textSize.Value, TextBackground = _textBg.IsChecked == true, LineWidth = _width.Value,
                }, isNew: true);
                break;
            case Tool.Counter:
                _dragging = false;
                _surface.ReleaseMouseCapture();
                _model.Checkpoint();
                _model.Annotations.Add(new Annotation { Kind = Tool.Counter, Start = p, End = p, Color = color, LineWidth = _width.Value, Number = _model.NextCounter() });
                _model.Changed();
                Commit();
                break;
            default:
                _drag = Drag.Draw;
                _canvas.Draft = new Annotation { Kind = _tool, Start = p, End = p, Color = color, LineWidth = _width.Value };
                if (_tool == Tool.Pen) _canvas.Draft.Points.Add(p);
                break;
        }
    }

    private void BeginHandle(Annotation sel, int index)
    {
        _model.Checkpoint();
        _moving = sel;
        _handleIndex = index;
        _drag = Drag.Handle;
    }

    private void OnMove(object sender, MouseEventArgs e)
    {
        if (!_dragging || e.LeftButton != MouseButtonState.Pressed) return;
        var p = CanvasPoint(e);
        var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        switch (_drag)
        {
            case Drag.Pan:
                var now = e.GetPosition(_scroll);
                _scroll.ScrollToHorizontalOffset(_panOffset.X - (now.X - _panStart.X));
                _scroll.ScrollToVerticalOffset(_panOffset.Y - (now.Y - _panStart.Y));
                return;
            case Drag.Move when _moving != null:
                _moving.Offset(p - _down);
                _down = p;
                break;
            case Drag.Handle when _moving != null:
                if (_handleIndex == 0) _moving.Start = p; else _moving.End = p;
                break;
            case Drag.Image:
                _model.ImageOrigin += p - _down;
                _down = p;
                break;
            case Drag.Crop:
                _canvas.CropRect = new Rect(_down, p);
                break;
            case Drag.Draw when _canvas.Draft is { } d:
                if (d.Kind == Tool.Pen) d.Points.Add(p);
                else d.End = shift ? Constrain(d.Start, p, d.Kind) : p;
                break;
        }
        _model.Changed();
        _canvas.InvalidateVisual();
    }

    /// <summary>Shift: 45° steps for lines/arrows, squares/circles for shapes.</summary>
    private static Point Constrain(Point a, Point b, Tool kind)
    {
        var v = b - a;
        if (kind is Tool.Line or Tool.Arrow)
        {
            var angle = Math.Round(Math.Atan2(v.Y, v.X) / (Math.PI / 4)) * (Math.PI / 4);
            return a + new Vector(Math.Cos(angle), Math.Sin(angle)) * v.Length;
        }
        var s = Math.Max(Math.Abs(v.X), Math.Abs(v.Y));
        return a + new Vector(Math.Sign(v.X) * s, Math.Sign(v.Y) * s);
    }

    private void OnUp(object sender, MouseButtonEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false;
        _surface.ReleaseMouseCapture();
        switch (_drag)
        {
            case Drag.Draw when _canvas.Draft is { } d:
                _canvas.Draft = null;
                var tiny = d.Kind == Tool.Pen ? d.Points.Count < 2 : (d.End - d.Start).Length < 3;
                if (!tiny)
                {
                    _model.Checkpoint();
                    _model.Annotations.Add(d);
                    _model.Changed();
                }
                break;
            case Drag.Crop:
                if (_canvas.CropRect is { } c && (c.Width < 4 || c.Height < 4)) _canvas.CropRect = null;
                else Flash("Enter to crop, Esc to cancel");
                break;
        }
        _drag = Drag.None;
        _moving = null;
        Commit();
    }

    /// <summary>Re-lays out the canvas (it may have grown) and refreshes the undo buttons.</summary>
    private void Commit()
    {
        _canvas.RecomputeLayout();
        RefreshUndo();
    }

    private void RefreshUndo()
    {
        _undo.IsEnabled = _model.CanUndo;
        _redo.IsEnabled = _model.CanRedo;
    }

    // MARK: - Inline text

    private void BeginTextEdit(Annotation a, bool isNew = false)
    {
        CommitText();
        _editingText = a;
        if (!isNew)
        {
            _model.Checkpoint();
            _model.Annotations.Remove(a); // drawn by the editor while editing
            _model.Changed();
            _canvas.InvalidateVisual();
        }
        _editor = new TextBox
        {
            Text = a.Text, FontSize = a.FontSize, FontWeight = FontWeights.SemiBold, FontFamily = new FontFamily("Segoe UI"),
            Foreground = new SolidColorBrush(a.TextColor), Background = a.TextBackground ? new SolidColorBrush(a.Color) : new SolidColorBrush(Color.FromArgb(0x30, 0x80, 0x80, 0x80)),
            BorderThickness = new Thickness(1), BorderBrush = Brushes.DodgerBlue, AcceptsReturn = true, MinWidth = 40,
            Padding = new Thickness(Annotation.TextPadding - 2), CaretBrush = new SolidColorBrush(a.TextColor),
        };
        Canvas.SetLeft(_editor, a.Start.X - _canvas.Origin.X);
        Canvas.SetTop(_editor, a.Start.Y - _canvas.Origin.Y);
        _overlay.Children.Add(_editor);
        _editor.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && !Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) { CommitText(); e.Handled = true; }
            else if (e.Key == Key.Escape) { CommitText(cancel: isNew); e.Handled = true; }
        };
        _editor.Loaded += (_, _) => { _editor?.Focus(); Keyboard.Focus(_editor); _editor?.SelectAll(); };
        _editor.Tag = isNew;
    }

    private void CommitText(bool cancel = false)
    {
        if (_editor == null || _editingText == null) return;
        var a = _editingText;
        var isNew = _editor.Tag is true;
        var text = _editor.Text.TrimEnd();
        _overlay.Children.Remove(_editor);
        _editor = null;
        _editingText = null;
        if (cancel || text.Length == 0)
        {
            if (!isNew) _model.Undo(); // restore the original
        }
        else
        {
            if (isNew) _model.Checkpoint();
            a.Text = text;
            _model.Annotations.Add(a);
            _model.Changed();
        }
        Keyboard.Focus(this);
        Commit();
    }

    // MARK: - Keys

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (_editor != null && _editor.IsKeyboardFocusWithin) return;
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        if (ctrl)
        {
            switch (e.Key)
            {
                case Key.C: Copy(); break;
                case Key.S: Save(); break;
                case Key.W: Close(); break;
                case Key.Z when shift: Redo(); break;
                case Key.Z: Undo(); break;
                case Key.Y: Redo(); break;
                case Key.D0: FitZoom(); break;
                case Key.D1: SetZoom(1 / VisualTreeHelper.GetDpi(this).DpiScaleX); break;
                case Key.OemPlus: case Key.Add: SetZoom(_zoom.ScaleX * 1.25); break;
                case Key.OemMinus: case Key.Subtract: SetZoom(_zoom.ScaleX / 1.25); break;
                case Key.OemComma: _host.OpenSettings("capture"); break;
                default: return;
            }
            e.Handled = true;
            return;
        }
        switch (e.Key)
        {
            case Key.Enter:
                if (_canvas.CropRect is { } crop) ApplyCrop(crop);
                else Copy();
                break;
            case Key.Delete:
            case Key.Back:
                if (_canvas.Selected is { } sel && _model.Annotations.Contains(sel))
                {
                    _model.Checkpoint();
                    _model.Annotations.Remove(sel);
                    _canvas.Selected = null;
                    _model.Changed();
                    Commit();
                }
                break;
            case Key.Escape:
                // Priority: cancel crop → deselect → select tool → (optionally) copy and close.
                if (_canvas.CropRect != null) { _canvas.CropRect = null; _canvas.InvalidateVisual(); }
                else if (_canvas.Selected != null) { _canvas.Selected = null; _canvas.InvalidateVisual(); }
                else if (_tool != Tool.Select) SetTool(Tool.Select);
                else if (Settings.EscCopiesAndCloses) { Copy(); Close(); }
                break;
            default:
                var ch = KeyChar(e.Key);
                if (ch == null) return;
                var tool = _keys.FirstOrDefault(kv => kv.Value == ch).Key;
                if (_keys.ContainsValue(ch.Value)) SetTool(tool);
                else return;
                break;
        }
        e.Handled = true;
    }

    private static char? KeyChar(Key k) => k is >= Key.A and <= Key.Z ? (char)('a' + (k - Key.A)) : null;

    private void ApplyCrop(Rect crop)
    {
        _model.ApplyCrop(crop);
        _canvas.CropRect = null;
        _canvas.Selected = null;
        SetTool(Tool.Select);
        Commit();
        FitZoom(initial: true);
    }

    private void Undo()
    {
        CommitText();
        _model.Undo();
        _canvas.Selected = null;
        Commit();
    }

    private void Redo()
    {
        _model.Redo();
        _canvas.Selected = null;
        Commit();
    }

    // MARK: - Output

    private BitmapSource Export()
    {
        CommitText();
        return ImageOutput.Prepare(_model.Flatten(), _model.CaptureScale, Settings);
    }

    private void Copy()
    {
        var ok = ImageOutput.Copy(Export());
        Flash(ok ? "Copied" : "Could not copy");
        if (ok && Settings.CloseAfterCopy) Close();
    }

    private void Save()
    {
        var (path, error) = ImageOutput.Save(Export(), Settings);
        if (error != null)
        {
            Flash("Save failed");
            MessageBox.Show(this, $"The image could not be saved: {error}", "Mukker", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        Flash($"Saved {System.IO.Path.GetFileName(path)}");
        if (Settings.CloseAfterSave) Close();
    }

    private void Flash(string text)
    {
        _flash.Text = text;
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2.5) };
        t.Tick += (_, _) => { t.Stop(); if (_flash.Text == text) _flash.Text = ""; };
        t.Start();
    }
}
