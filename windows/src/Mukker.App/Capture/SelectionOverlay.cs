using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Mukker.App.Interop;

namespace Mukker.App.Capture;

/// <summary>
/// Full-screen overlays, one per monitor, showing the frozen screenshot dimmed outside the selection,
/// with a crosshair, a live size badge and an optional loupe. Esc or a selection under 4 px cancels.
/// </summary>
internal sealed class SelectionSession
{
    private readonly List<OverlayWindow> _windows = new();
    private readonly TaskCompletionSource<Int32Rect?> _tcs = new();

    /// <summary>Lets the user drag a rectangle; returns it in virtual-screen pixels, or null if cancelled.</summary>
    public static Task<Int32Rect?> Select(Grab frozen, bool loupe, int minSize = 4)
    {
        var s = new SelectionSession();
        foreach (var m in ScreenGrabber.Monitors())
        {
            var local = new Int32Rect(m.Bounds.X - frozen.Bounds.X, m.Bounds.Y - frozen.Bounds.Y, m.Bounds.Width, m.Bounds.Height);
            var w = new OverlayWindow(s, frozen.Crop(local), m, loupe, minSize);
            s._windows.Add(w);
            w.ShowOn(m);
        }
        Native.GetCursorPos(out var p);
        foreach (var w in s._windows)
            if (w.Contains(p.X, p.Y)) { w.Activate(); w.Focus(); }
        return s._tcs.Task;
    }

    public void Finish(Int32Rect? result)
    {
        foreach (var w in _windows) w.Close();
        _windows.Clear();
        _tcs.TrySetResult(result);
    }
}

internal sealed class OverlayWindow : Window
{
    private readonly SelectionSession _session;
    private readonly MonitorInfo _monitor;
    private readonly Grab _grab;
    private readonly BitmapSource _image;
    private readonly bool _loupe;
    private readonly int _minSize;
    private readonly Canvas _canvas = new();
    private readonly Path _dim = new() { Fill = new SolidColorBrush(Color.FromArgb(0x70, 0, 0, 0)), IsHitTestVisible = false };
    private readonly Rectangle _frame = new() { Stroke = Brushes.White, StrokeThickness = 1, IsHitTestVisible = false, Visibility = Visibility.Collapsed };
    private readonly Border _badge = new() { Background = new SolidColorBrush(Color.FromArgb(0xD0, 0x20, 0x20, 0x22)), CornerRadius = new CornerRadius(4), Padding = new Thickness(6, 2, 6, 2), IsHitTestVisible = false, Visibility = Visibility.Collapsed };
    private readonly TextBlock _badgeText = new() { Foreground = Brushes.White, FontSize = 11, FontFamily = new FontFamily("Cascadia Mono, Consolas") };
    private readonly Border _loupeBox = new() { Width = 130, Height = 150, BorderBrush = Brushes.White, BorderThickness = new Thickness(2), Background = Brushes.Black, IsHitTestVisible = false, Visibility = Visibility.Collapsed, CornerRadius = new CornerRadius(4) };
    private readonly Image _loupeImage = new() { Width = 126, Height = 126, Stretch = Stretch.Fill };
    private readonly TextBlock _loupeText = new() { Foreground = Brushes.White, FontSize = 10, HorizontalAlignment = HorizontalAlignment.Center, FontFamily = new FontFamily("Cascadia Mono, Consolas") };
    private Point? _start;
    private Point _current;

    public OverlayWindow(SelectionSession session, Grab grab, MonitorInfo monitor, bool loupe, int minSize)
    {
        _session = session;
        _grab = grab;
        _monitor = monitor;
        _loupe = loupe;
        _minSize = minSize;
        _image = grab.ToBitmap();
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Cursor = Cursors.Cross;
        Background = Brushes.Black;

        var root = new Grid();
        root.Children.Add(new Image { Source = _image, Stretch = Stretch.Fill });
        root.Children.Add(_canvas);
        _canvas.Children.Add(_dim);
        _canvas.Children.Add(_frame);
        _badge.Child = _badgeText;
        _canvas.Children.Add(_badge);
        RenderOptions.SetBitmapScalingMode(_loupeImage, BitmapScalingMode.NearestNeighbor);
        var lp = new StackPanel();
        lp.Children.Add(_loupeImage);
        lp.Children.Add(_loupeText);
        _loupeBox.Child = lp;
        _canvas.Children.Add(_loupeBox);
        Content = root;

        MouseLeftButtonDown += (_, e) => { _start = e.GetPosition(this); CaptureMouse(); Update(); };
        MouseMove += (_, e) => { _current = e.GetPosition(this); Update(); };
        MouseLeftButtonUp += (_, e) =>
        {
            if (_start is not { } s) return;
            ReleaseMouseCapture();
            var r = PixelRect(s, e.GetPosition(this));
            _start = null;
            _session.Finish(r.Width < _minSize || r.Height < _minSize ? null : r);
        };
        MouseRightButtonUp += (_, _) => _session.Finish(null);
        KeyDown += (_, e) => { if (e.Key == Key.Escape) _session.Finish(null); };
        Loaded += (_, _) => Update();
    }

    public bool Contains(int x, int y) =>
        x >= _monitor.Bounds.X && x < _monitor.Bounds.X + _monitor.Bounds.Width && y >= _monitor.Bounds.Y && y < _monitor.Bounds.Y + _monitor.Bounds.Height;

    /// <summary>Places the window over the monitor in physical pixels, independent of WPF's DPI guesses.</summary>
    public void ShowOn(MonitorInfo m)
    {
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = m.Bounds.X / m.Scale;
        Top = m.Bounds.Y / m.Scale;
        Width = m.Bounds.Width / m.Scale;
        Height = m.Bounds.Height / m.Scale;
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, m.Bounds.X, m.Bounds.Y, m.Bounds.Width, m.Bounds.Height, Native.SWP_SHOWWINDOW);
        };
        Show();
        var hwnd2 = new WindowInteropHelper(this).Handle;
        Native.SetWindowPos(hwnd2, Native.HWND_TOPMOST, m.Bounds.X, m.Bounds.Y, m.Bounds.Width, m.Bounds.Height, Native.SWP_SHOWWINDOW);
    }

    private double ScaleX => ActualWidth > 0 ? _grab.Width / ActualWidth : 1;
    private double ScaleY => ActualHeight > 0 ? _grab.Height / ActualHeight : 1;

    /// <summary>Selection in virtual-screen pixels.</summary>
    private Int32Rect PixelRect(Point a, Point b)
    {
        var x0 = (int)Math.Round(Math.Min(a.X, b.X) * ScaleX);
        var y0 = (int)Math.Round(Math.Min(a.Y, b.Y) * ScaleY);
        var x1 = (int)Math.Round(Math.Max(a.X, b.X) * ScaleX);
        var y1 = (int)Math.Round(Math.Max(a.Y, b.Y) * ScaleY);
        x0 = Math.Clamp(x0, 0, _grab.Width); x1 = Math.Clamp(x1, 0, _grab.Width);
        y0 = Math.Clamp(y0, 0, _grab.Height); y1 = Math.Clamp(y1, 0, _grab.Height);
        return new Int32Rect(_grab.Bounds.X + x0, _grab.Bounds.Y + y0, x1 - x0, y1 - y0);
    }

    private void Update()
    {
        var full = new RectangleGeometry(new Rect(0, 0, ActualWidth, ActualHeight));
        if (_start is { } s)
        {
            var sel = new Rect(s, _current);
            _dim.Data = new CombinedGeometry(GeometryCombineMode.Exclude, full, new RectangleGeometry(sel));
            _frame.Visibility = Visibility.Visible;
            Canvas.SetLeft(_frame, sel.X);
            Canvas.SetTop(_frame, sel.Y);
            _frame.Width = sel.Width;
            _frame.Height = sel.Height;
            var px = PixelRect(s, _current);
            _badgeText.Text = $"{px.Width} × {px.Height}";
            _badge.Visibility = Visibility.Visible;
            Canvas.SetLeft(_badge, sel.X);
            Canvas.SetTop(_badge, sel.Y > 24 ? sel.Y - 22 : sel.Bottom + 4);
        }
        else
        {
            _dim.Data = full;
            _frame.Visibility = Visibility.Collapsed;
            _badge.Visibility = Visibility.Collapsed;
        }
        UpdateLoupe();
    }

    private void UpdateLoupe()
    {
        if (!_loupe || !IsMouseOver) { _loupeBox.Visibility = Visibility.Collapsed; return; }
        const int sample = 26;
        var cx = (int)(_current.X * ScaleX);
        var cy = (int)(_current.Y * ScaleY);
        var x = Math.Clamp(cx - sample / 2, 0, Math.Max(0, _grab.Width - sample));
        var y = Math.Clamp(cy - sample / 2, 0, Math.Max(0, _grab.Height - sample));
        if (_grab.Width < sample || _grab.Height < sample) return;
        _loupeImage.Source = new CroppedBitmap(_image, new Int32Rect(x, y, sample, sample));
        var i = (Math.Clamp(cy, 0, _grab.Height - 1) * _grab.Width + Math.Clamp(cx, 0, _grab.Width - 1)) * 4;
        _loupeText.Text = $"#{_grab.Pixels[i + 2]:X2}{_grab.Pixels[i + 1]:X2}{_grab.Pixels[i]:X2}";
        _loupeBox.Visibility = Visibility.Visible;
        var lx = _current.X + 20 + 130 > ActualWidth ? _current.X - 150 : _current.X + 20;
        var ly = _current.Y + 20 + 150 > ActualHeight ? _current.Y - 170 : _current.Y + 20;
        Canvas.SetLeft(_loupeBox, lx);
        Canvas.SetTop(_loupeBox, ly);
    }
}
