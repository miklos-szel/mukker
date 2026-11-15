using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
using Mukker.App.Clipboard;
using Mukker.App.Interop;
using Mukker.App.Popup;
using Mukker.Core.Clipboard;
using Mukker.Core.Settings;
using Mukker.Core.Translate;

namespace Mukker.App.Translate;

/// <summary>
/// The floating translate panel: header (the drag handle), the editable source, the result, and the buttons.
/// It does not close on losing focus — the user reads it while working elsewhere. Resizable by its edges;
/// size and position are written back to the settings when a drag ends, so it reopens where and as it was left.
/// Pure presentation: every action goes through <see cref="TranslationController"/>.
/// </summary>
internal sealed class TranslationPanel : Window
{
    private const int WM_EXITSIZEMOVE = 0x0232;

    private readonly TranslationController _controller;
    private readonly AppHost _host;
    private readonly Border _frame = new();
    private readonly TextBlock _header = new() { FontWeight = FontWeights.SemiBold, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly Grid _body = new();
    private readonly TextBox _source = new()
    {
        TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, AcceptsTab = false, FontSize = 12,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalContentAlignment = VerticalAlignment.Top,
        BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(0),
    };
    private readonly Border _sourceBox;
    private readonly TextBlock _editedHint = new() { Text = "Edited — Esc keeps it open", FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _copy = new() { Content = "Copy", MinWidth = 72 };
    private readonly Button _target = new() { MinWidth = 140, ToolTip = "Ctrl+Enter" };
    private readonly Button _other = new() { MinWidth = 140 };
    private readonly Button _close = new() { Content = "Close", MinWidth = 72, ToolTip = "Close (Ctrl+W)" };
    private PanelState? _state;
    private TranslationOrigin _origin;
    private TranslationBackend _backend;
    private bool _syncing;
    private bool _placing;
    private bool _shownInactive;

    public TranslationPanel(TranslationController controller, AppHost host)
    {
        _controller = controller;
        _host = host;
        Title = "Mukker Translate";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.CanResize;
        // Edge/corner resizing without a title bar; the header below is the drag handle.
        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 0, ResizeBorderThickness = new Thickness(6), GlassFrameThickness = new Thickness(0),
            CornerRadius = new CornerRadius(0), UseAeroCaptionButtons = false,
        });
        MinWidth = TranslationSettings.PanelWidthRange.Min;
        MaxWidth = TranslationSettings.PanelWidthRange.Max;
        MinHeight = TranslationSettings.PanelHeightRange.Min;
        MaxHeight = TranslationSettings.PanelHeightRange.Max;
        Topmost = true;
        ShowInTaskbar = false;
        Background = (Brush)FindResource("Surface");
        _copy.Style = (Style)FindResource("AccentButton");
        _editedHint.Foreground = (Brush)FindResource("InkSoft");

        var root = new DockPanel { Margin = new Thickness(16, 10, 16, 14) };

        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 8), Background = Brushes.Transparent, Cursor = Cursors.SizeAll };
        var x = new Button { Content = "", Style = (Style)FindResource("IconButton"), ToolTip = "Close (Ctrl+W)", Cursor = Cursors.Arrow };
        x.Click += (_, _) => _controller.Close();
        DockPanel.SetDock(x, Dock.Right);
        top.Children.Add(x);
        top.Children.Add(_header);
        top.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ButtonState != MouseButtonState.Pressed || e.OriginalSource is DependencyObject d && IsInside<Button>(d)) return;
            try { DragMove(); } catch { }
        };
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);

        var footer = new DockPanel { Margin = new Thickness(0, 10, 0, 0), LastChildFill = false };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        _close.Margin = _other.Margin = _target.Margin = new Thickness(0, 0, 8, 0);
        buttons.Children.Add(_close);
        buttons.Children.Add(_other);
        buttons.Children.Add(_target);
        buttons.Children.Add(_copy);
        DockPanel.SetDock(buttons, Dock.Right);
        DockPanel.SetDock(_editedHint, Dock.Left);
        footer.Children.Add(buttons);
        footer.Children.Add(_editedHint);
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);

        _sourceBox = new Border
        {
            Child = _source, Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(0, 0, 0, 10), CornerRadius = new CornerRadius(6),
            Background = (Brush)FindResource("SurfaceAlt"), BorderThickness = new Thickness(1),
        };
        DockPanel.SetDock(_sourceBox, Dock.Top);
        root.Children.Add(_sourceBox);
        root.Children.Add(_body);

        _frame.Child = root;
        Content = _frame;

        _source.TextChanged += (_, _) =>
        {
            if (_syncing) return;
            _controller.Draft = _source.Text;
            RefreshChrome();
        };
        _close.Click += (_, _) => _controller.Close();
        _copy.Click += (_, _) => { if (_state is PanelState.Done d) Paster.CopyText(d.Result); };
        _target.Click += (_, _) => { if (_state != null) _controller.TranslateDraft(_state.Language); };
        _other.Click += (_, _) => { if (_state != null) _controller.TranslateDraft(_state.Language.Other()); };
        // Window-level, so these are seen before the source TextBox (which would insert a newline for Ctrl+Enter).
        PreviewKeyDown += (_, e) =>
        {
            var mods = Keyboard.Modifiers;
            if (e.Key == Key.Escape && mods == ModifierKeys.None)
            {
                _controller.Escape();
                e.Handled = true;
            }
            else if (e.Key == Key.W && mods == ModifierKeys.Control)
            {
                _controller.Close();
                e.Handled = true;
            }
            else if (e.Key == Key.Enter && mods == ModifierKeys.Control)
            {
                _controller.Submit();
                e.Handled = true;
            }
        };
        SizeChanged += (_, _) => _sourceBox.Height = Math.Max(56, Math.Round(ActualHeight * 0.3));
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            Native.RoundCorners(hwnd);
            HwndSource.FromHwnd(hwnd)?.AddHook(WndProc);
        };
        ApplySettings();
    }

    private static bool IsInside<T>(DependencyObject d) where T : DependencyObject
    {
        for (var cur = d; cur != null; cur = cur is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(cur) : LogicalTreeHelper.GetParent(cur))
            if (cur is T) return true;
        return false;
    }

    private IntPtr Handle => new WindowInteropHelper(this).Handle;

    public bool IsForeground => IsVisible && Native.GetForegroundWindow() == Handle;

    private TranslationSettings Settings => _host.Settings.Current.Translation;

    /// <summary>A move or edge drag just ended: remember it, so the Settings sliders follow and the next open uses it.</summary>
    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_EXITSIZEMOVE && !_placing && Native.GetWindowRect(hwnd, out var r))
        {
            var w = Math.Round(ActualWidth);
            var h = Math.Round(ActualHeight);
            var s = Settings;
            if (s.PanelLeft != r.Left || s.PanelTop != r.Top || s.PanelWidth != w || s.PanelHeight != h)
            {
                _host.Settings.Update(a =>
                {
                    a.Translation.PanelLeft = r.Left;
                    a.Translation.PanelTop = r.Top;
                    a.Translation.PanelWidth = w;
                    a.Translation.PanelHeight = h;
                });
            }
        }
        return IntPtr.Zero;
    }

    /// <summary>Size and border from the settings; a size change keeps the top-left corner where it is.</summary>
    public void ApplySettings()
    {
        var s = Settings;
        _placing = true;
        try
        {
            var w = s.ClampedPanelWidth;
            var h = s.ClampedPanelHeight;
            if (Math.Abs(Width - w) > 0.5 || double.IsNaN(Width)) Width = w;
            if (Math.Abs(Height - h) > 0.5 || double.IsNaN(Height)) Height = h;
        }
        finally { _placing = false; }

        var bw = s.ClampedBorderWidth;
        if (s.BorderEnabled && bw > 0)
        {
            _frame.BorderBrush = new SolidColorBrush(PopupWindow.ParseColor(s.BorderColor, Color.FromRgb(0xE6, 0x97, 0x18)));
            _frame.BorderThickness = new Thickness(bw);
        }
        else
        {
            _frame.BorderBrush = (Brush)FindResource("Hairline");
            _frame.BorderThickness = new Thickness(1);
        }
    }

    public void Render(PanelState state, TranslationOrigin origin, TranslationBackend backend)
    {
        _state = state;
        _origin = origin;
        _backend = backend;
        if (_source.Text != _controller.Draft)
        {
            _syncing = true;
            _source.Text = _controller.Draft;
            _source.CaretIndex = _source.Text.Length;
            _syncing = false;
        }
        _target.Content = $"Translate to {state.Language.Label()}";
        _other.Content = $"Translate to {state.Language.Other().Label()}";
        _sourceBox.Visibility = state is PanelState.Reading ? Visibility.Collapsed : Visibility.Visible;
        _body.Children.Clear();
        switch (state)
        {
            case PanelState.Reading:
                _body.Children.Add(Spinner("Reading the selection…"));
                break;
            case PanelState.Translating:
                _body.Children.Add(Spinner("Translating…"));
                break;
            case PanelState.Done d:
                _body.Children.Add(new TextBox
                {
                    Text = d.Result, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0),
                    Background = Brushes.Transparent, FontSize = 14, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                    VerticalContentAlignment = VerticalAlignment.Top, Padding = new Thickness(0),
                });
                break;
            case PanelState.Failed f:
                _body.Children.Add(new TextBox
                {
                    Text = f.Message, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0),
                    Background = Brushes.Transparent, Foreground = (Brush)FindResource("Danger"), VerticalContentAlignment = VerticalAlignment.Top,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                });
                break;
        }
        RefreshChrome();
    }

    private UIElement Spinner(string text)
    {
        var spin = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        spin.Children.Add(new ProgressBar { IsIndeterminate = true, Width = 160, Height = 4, Margin = new Thickness(0, 0, 0, 10) });
        spin.Children.Add(new TextBlock { Text = text, Foreground = (Brush)FindResource("InkSoft"), HorizontalAlignment = HorizontalAlignment.Center });
        return spin;
    }

    /// <summary>Everything that depends on whether the source has been edited: header, hint, outline, buttons.</summary>
    private void RefreshChrome()
    {
        if (_state == null) return;
        var edited = _controller.IsDraftEdited;
        var header = $"→ {_state.Language.Label()} · {_backend.ShortName()}";
        if (!edited && _state.SentText.Length > 0) header += $" · {_origin.Origin()}";
        _header.Text = header;
        _editedHint.Visibility = edited ? Visibility.Visible : Visibility.Collapsed;
        _source.Foreground = edited ? (Brush)FindResource("Ink") : (Brush)FindResource("InkSoft");
        _sourceBox.BorderBrush = edited ? (Brush)FindResource("Accent") : Brushes.Transparent;
        var canTranslate = !_state.IsBusy && !ClipText.IsBlank(_controller.Draft);
        _target.IsEnabled = _other.IsEnabled = canTranslate;
        _copy.IsEnabled = _state is PanelState.Done;
    }

    /// <summary>
    /// Shows the panel at the remembered spot if its top strip is still on a screen, else centred on the screen
    /// with the mouse. Without <paramref name="activate"/> it doesn't take focus — used while a Chromium app is
    /// still building the accessibility tree its selection is read from.
    /// </summary>
    public void ShowPlaced(bool activate)
    {
        _placing = true;
        try
        {
            ApplySettings();
            WindowStartupLocation = WindowStartupLocation.Manual;
            ShowActivated = activate;
            Left = -10000;
            Top = -10000;
            Show();
            var hwnd = Handle;
            var s = Settings;
            if (s.PanelLeft is { } px && s.PanelTop is { } py && TopStripVisible((int)px, (int)py))
            {
                Native.SetWindowPos(hwnd, IntPtr.Zero, (int)px, (int)py, 0, 0, Native.SWP_NOSIZE | Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
            }
            else
            {
                var work = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position).WorkingArea;
                Native.GetWindowRect(hwnd, out var r);
                Native.SetWindowPos(hwnd, IntPtr.Zero, work.Left + (work.Width - r.Width) / 2, work.Top + (work.Height - r.Height) / 2, 0, 0,
                    Native.SWP_NOSIZE | Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
            }
        }
        finally { _placing = false; }

        if (activate) ActivateNow();
        else _shownInactive = true;
    }

    /// <summary>The panel was shown without focus (reading a Chromium selection); take it now the text is in.</summary>
    public void ActivateIfInactive()
    {
        if (!_shownInactive) return;
        ActivateNow();
    }

    private void ActivateNow()
    {
        _shownInactive = false;
        Native.ForceForeground(Handle);
        Activate();
    }

    /// <summary>At least the header strip (in physical pixels) must be reachable to drag the panel back.</summary>
    private static bool TopStripVisible(int left, int top)
    {
        var strip = new System.Drawing.Rectangle(left, top, 200, 40);
        foreach (var screen in System.Windows.Forms.Screen.AllScreens)
            if (screen.WorkingArea.IntersectsWith(strip)) return true;
        return false;
    }
}
