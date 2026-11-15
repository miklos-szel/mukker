using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Mukker.App.Clipboard;
using Mukker.App.Interop;
using Mukker.Core.Settings;
using Mukker.Core.Translate;

namespace Mukker.App.Translate;

/// <summary>
/// The floating result panel. Unlike the popup it does not close on losing focus — the user reads it while
/// working elsewhere. Esc, Ctrl+W, Close or the same language's hotkey close it.
/// </summary>
internal sealed class TranslationPanel : Window
{
    private readonly TranslationController _controller;
    private readonly TextBlock _header = new() { FontWeight = FontWeights.SemiBold, FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
    private readonly Grid _body = new();
    private readonly TextBlock _source = new() { TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis, FontSize = 11, MaxHeight = 72 };
    private readonly Button _copy = new() { Content = "Copy", MinWidth = 72 };
    private readonly Button _other = new() { MinWidth = 150 };
    private readonly Button _close = new() { Content = "Close", MinWidth = 72 };
    private PanelState? _state;

    public TranslationPanel(TranslationController controller, AppHost host)
    {
        _controller = controller;
        Title = "Mukker Translate";
        Width = 520;
        Height = 320;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.CanResizeWithGrip;
        MinWidth = 380;
        MinHeight = 220;
        Topmost = true;
        ShowInTaskbar = false;
        Background = (Brush)FindResource("Surface");
        _source.Foreground = (Brush)FindResource("InkSoft");
        _copy.Style = (Style)FindResource("AccentButton");

        var root = new DockPanel { Margin = new Thickness(16, 12, 16, 14) };
        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var x = new Button { Content = "", Style = (Style)FindResource("IconButton"), ToolTip = "Close (Esc)" };
        x.Click += (_, _) => _controller.Close();
        DockPanel.SetDock(x, Dock.Right);
        top.Children.Add(x);
        top.Children.Add(_header);
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        _close.Margin = new Thickness(0, 0, 8, 0);
        _other.Margin = new Thickness(0, 0, 8, 0);
        buttons.Children.Add(_close);
        buttons.Children.Add(_other);
        buttons.Children.Add(_copy);
        DockPanel.SetDock(buttons, Dock.Bottom);
        root.Children.Add(buttons);

        var sourceBox = new Border
        {
            Child = _source, Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(0, 8, 0, 0), CornerRadius = new CornerRadius(6),
            Background = (Brush)FindResource("SurfaceAlt"),
        };
        DockPanel.SetDock(sourceBox, Dock.Bottom);
        root.Children.Add(sourceBox);
        root.Children.Add(_body);

        Content = new Border { Child = root, BorderBrush = (Brush)FindResource("Hairline"), BorderThickness = new Thickness(1) };

        _close.Click += (_, _) => _controller.Close();
        _copy.Click += (_, _) => { if (_state is PanelState.Done d) Paster.CopyText(d.Result); };
        _other.Click += (_, _) =>
        {
            if (_state is { } s && Source(s) is { Length: > 0 } src) _controller.Translate(src, s.Language.Other(), _controller.Origin);
        };
        MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed) try { DragMove(); } catch { } };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape || (e.Key == Key.W && Keyboard.Modifiers == ModifierKeys.Control))
            {
                _controller.Close();
                e.Handled = true;
            }
        };
        SourceInitialized += (_, _) => Native.RoundCorners(new WindowInteropHelper(this).Handle);
    }

    private static string Source(PanelState s) => s switch
    {
        PanelState.Translating t => t.Source,
        PanelState.Done d => d.Source,
        PanelState.Failed f => f.Source,
        _ => "",
    };

    public void Render(PanelState state, TranslationOrigin origin, TranslationBackend backend)
    {
        _state = state;
        _header.Text = $"→ {state.Language.Label()} · {backend.ShortName()} · {origin.Origin()}";
        _other.Content = $"Translate to {state.Language.Other().Label()}";
        _body.Children.Clear();
        var src = Source(state);
        _source.Text = src.Length > 600 ? src[..600] + "…" : src;
        ((Border)_source.Parent).Visibility = src.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        _copy.IsEnabled = state is PanelState.Done;
        _other.IsEnabled = src.Length > 0 && state is not PanelState.Translating;
        switch (state)
        {
            case PanelState.Translating:
                var spin = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
                spin.Children.Add(new ProgressBar { IsIndeterminate = true, Width = 160, Height = 4, Margin = new Thickness(0, 0, 0, 10) });
                spin.Children.Add(new TextBlock { Text = "Translating…", Foreground = (Brush)FindResource("InkSoft"), HorizontalAlignment = HorizontalAlignment.Center });
                _body.Children.Add(spin);
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
                });
                break;
        }
    }

    /// <summary>Centred on the screen that has the mouse.</summary>
    public void ShowCentered()
    {
        var cursor = System.Windows.Forms.Cursor.Position;
        var work = System.Windows.Forms.Screen.FromPoint(cursor).WorkingArea;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = -10000;
        Top = -10000;
        Show();
        var m = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var tl = m.Transform(new Point(work.Left, work.Top));
        var br = m.Transform(new Point(work.Right, work.Bottom));
        Left = tl.X + (br.X - tl.X - Width) / 2;
        Top = tl.Y + (br.Y - tl.Y - Height) / 2;
        Native.ForceForeground(new WindowInteropHelper(this).Handle);
        Activate();
    }
}
