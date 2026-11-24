using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using Mukker.App.Interop;

namespace Mukker.App.Dictation;

/// <summary>
/// The small pill at the bottom of the screen while dictating: a red dot and live level meter while recording, a
/// spinner while transcribing, a one-line notice otherwise. Click-through and non-activating — the user is typing
/// into another app. Notices show even with the indicator switched off (they explain why nothing happened).
/// Bottom-centre of the monitor under the cursor, 48 DIPs above the work area.
/// </summary>
internal sealed class DictationOverlay : Window
{
    private const double PillWidth = 260, PillHeight = 44, BottomMargin = 48;
    private static readonly double[] Weights = [0.45, 0.7, 0.9, 1, 0.9, 0.7, 0.45];

    private readonly DictationService _service;
    private readonly Func<bool> _overlayEnabled;
    private readonly StackPanel _row = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Border[] _bars = new Border[Weights.Length];
    private readonly Canvas _spinner = new() { Width = 16, Height = 16 };
    private readonly RotateTransform _spin = new(0, 8, 8);
    private IntPtr _hwnd;

    public DictationOverlay(DictationService service, Func<bool> overlayEnabled)
    {
        _service = service;
        _overlayEnabled = overlayEnabled;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Focusable = false;
        ResizeMode = ResizeMode.NoResize;
        Width = PillWidth;
        Height = PillHeight;
        Title = "Mukker Dictation";

        Content = new Border
        {
            CornerRadius = new CornerRadius(PillHeight / 2),
            Background = new SolidColorBrush(Color.FromArgb(0xD1, 0, 0, 0)), // black at 82 %
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x26, 255, 255, 255)), // white at 15 %
            BorderThickness = new Thickness(1),
            Padding = new Thickness(16, 0, 16, 0),
            Child = _row,
        };

        for (var i = 0; i < _bars.Length; i++)
            _bars[i] = new Border { Width = 3, Height = 3, CornerRadius = new CornerRadius(1.5), Background = Brushes.White, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(i == 0 ? 0 : 3, 0, 0, 0) };

        var arc = new Path
        {
            Stroke = Brushes.White, StrokeThickness = 2, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
            Data = Geometry.Parse("M 8,1.5 A 6.5,6.5 0 1 1 1.5,8"),
            RenderTransform = _spin,
        };
        _spinner.Children.Add(arc);
        _spin.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(0.9)) { RepeatBehavior = RepeatBehavior.Forever });

        SourceInitialized += (_, _) =>
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            var ex = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE, ex | Native.WS_EX_TRANSPARENT | Native.WS_EX_LAYERED | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW);
        };

        _service.StateChanged += Update;
        _service.LevelChanged += SetLevel;
    }

    /// <summary>Shows or hides the pill for the service's current state.</summary>
    public void Update()
    {
        var state = _service.State;
        var show = state.Phase switch
        {
            DictationPhase.Idle => false,
            DictationPhase.Notice => true,
            _ => _overlayEnabled(),
        };
        if (!show)
        {
            if (IsVisible) Hide();
            return;
        }

        _row.Children.Clear();
        switch (state.Phase)
        {
            case DictationPhase.Recording:
                _row.Children.Add(new Ellipse { Width = 9, Height = 9, Fill = Brushes.Red, VerticalAlignment = VerticalAlignment.Center });
                var meter = new StackPanel { Orientation = Orientation.Horizontal, Height = 20, Margin = new Thickness(10, 0, 10, 0) };
                foreach (var b in _bars) meter.Children.Add(b);
                _row.Children.Add(meter);
                _row.Children.Add(Label("Listening"));
                SetLevel(_service.Level);
                break;
            case DictationPhase.Transcribing:
                _row.Children.Add(_spinner);
                _row.Children.Add(Label("Transcribing…", 10));
                break;
            case DictationPhase.Notice:
                _row.Children.Add(new Grid
                {
                    Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Center,
                    Children =
                    {
                        new Ellipse { Stroke = Brushes.White, StrokeThickness = 1.5 },
                        new TextBlock { Text = "!", Foreground = Brushes.White, FontSize = 11, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
                    },
                });
                var text = Label(state.Message ?? "", 10);
                text.MaxWidth = PillWidth - 32 - 26 - 10;
                text.TextWrapping = TextWrapping.Wrap;
                text.TextTrimming = TextTrimming.CharacterEllipsis;
                text.MaxHeight = 32;
                _row.Children.Add(text);
                break;
        }
        Place();
    }

    private static TextBlock Label(string text, double left = 0) => new()
    {
        Text = text, Foreground = Brushes.White, FontSize = 12, FontWeight = FontWeights.Medium,
        VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(left, 0, 0, 0),
    };

    private void SetLevel(float level)
    {
        if (_service.State.Phase != DictationPhase.Recording) return;
        for (var i = 0; i < _bars.Length; i++) _bars[i].Height = Math.Max(3, 20 * level * Weights[i]);
    }

    private void Place()
    {
        if (!IsVisible)
        {
            // Create the handle first so the position can be set in pixels before the window appears.
            _hwnd = new WindowInteropHelper(this).EnsureHandle();
        }
        Native.GetCursorPos(out var cursor);
        var monitor = Native.MonitorFromPoint(cursor, 2 /* MONITOR_DEFAULTTONEAREST */);
        var info = new Native.MONITORINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<Native.MONITORINFO>() };
        if (!Native.GetMonitorInfo(monitor, ref info)) return;
        var scale = 1.0;
        try { if (Native.GetDpiForMonitor(monitor, 0, out var dx, out _) == 0) scale = dx / 96.0; } catch { }
        var w = (int)Math.Round(PillWidth * scale);
        var h = (int)Math.Round(PillHeight * scale);
        var x = info.rcWork.Left + (info.rcWork.Width - w) / 2;
        var y = info.rcWork.Bottom - h - (int)Math.Round(BottomMargin * scale);
        Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, x, y, w, h, Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        if (!IsVisible) Show(); // ShowActivated = false
        Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, x, y, w, h, Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
    }

    protected override void OnClosed(EventArgs e)
    {
        _service.StateChanged -= Update;
        _service.LevelChanged -= SetLevel;
        base.OnClosed(e);
    }
}
