using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Mukker.App.Interop;
using Mukker.App.Snippets;
using Mukker.Core.Settings;
using Mukker.Core.Storage;

namespace Mukker.App.Popup;

/// <summary>Shows/hides the popup and remembers which window to paste back into.</summary>
internal sealed class PopupController
{
    private readonly AppHost _host;
    private PopupWindow? _window;
    public IntPtr TargetWindow { get; private set; }

    public PopupController(AppHost host) => _host = host;

    /// <summary>The hotkey toggles: a second press closes the popup.</summary>
    public void Toggle()
    {
        if (_window is { IsVisible: true }) _window.HidePopup();
        else Show();
    }

    public void Show()
    {
        // Capture the target before we activate, or we lose it.
        var fg = Native.GetForegroundWindow();
        if (!Native.IsOwnWindow(fg)) TargetWindow = fg;
        _window ??= new PopupWindow(_host, this);
        _window.ShowPopup();
    }

    public void Restore()
    {
        if (TargetWindow != IntPtr.Zero) Native.ForceForeground(TargetWindow);
    }
}

public partial class PopupWindow : Window
{
    public const double BaseWidth = 820, BaseHeight = 480;
    private const int PageSize = 50;

    private readonly AppHost _host;
    private readonly PopupController _controller;
    private readonly ObservableCollection<PopupRow> _rows = new();
    private SnippetCollection? _collection; // drilled-in collection, null at top level
    private int _clipsLoaded;
    private bool _hasMoreClips;
    private bool _modal;
    private bool _hiding;

    internal PopupWindow(AppHost host, PopupController controller)
    {
        _host = host;
        _controller = controller;
        InitializeComponent();
        Results.ItemsSource = _rows;
        Deactivated += (_, _) => { if (!_modal) HidePopup(restoreFocus: false); };
        PreviewKeyDown += WindowKeyDown;
        SourceInitialized += (_, _) =>
        {
            // A tool window: no Alt+Tab entry.
            var hwnd = new WindowInteropHelper(this).Handle;
            const int GWL_EXSTYLE = -20, WS_EX_TOOLWINDOW = 0x80;
            SetWindowLong(hwnd, GWL_EXSTYLE, GetWindowLong(hwnd, GWL_EXSTYLE) | WS_EX_TOOLWINDOW);
        };
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr h, int i);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr h, int i, int v);

    private ClipboardSettings Settings => _host.Settings.Current.Clipboard;

    internal void ShowPopup()
    {
        ApplyAppearance();
        _collection = null;
        Search.Text = "";
        Rebuild();
        Show();
        Native.ForceForeground(new WindowInteropHelper(this).Handle);
        Activate();
        Search.Focus();
        Keyboard.Focus(Search);
    }

    internal void HidePopup(bool restoreFocus = true)
    {
        if (_hiding || !IsVisible) return;
        _hiding = true;
        Hide();
        _hiding = false;
        if (restoreFocus) _controller.Restore();
    }

    /// <summary>Sized as a percentage of the work area of the screen with the cursor, keeping the 820×480 ratio.</summary>
    private void ApplyAppearance()
    {
        var s = Settings;
        var cursor = System.Windows.Forms.Cursor.Position;
        var screen = System.Windows.Forms.Screen.FromPoint(cursor);
        var dpi = VisualTreeHelper.GetDpi(this);
        var scale = GetScaleForScreen(screen) ?? dpi.DpiScaleX;
        var work = screen.WorkingArea;
        var workW = work.Width / scale;
        var workH = work.Height / scale;
        var pct = Math.Clamp(s.PopupSizePercent, 0.3, 0.9);
        var fit = Math.Min(workW * pct / BaseWidth, workH * pct / BaseHeight);
        Width = BaseWidth * fit + 20;   // + shadow margin
        Height = BaseHeight * fit + 20;
        Left = work.Left / scale + (workW - Width) / 2;
        Top = work.Top / scale + (workH - Height) / 2;

        Bezel.Background = s.PopupCustomBackgroundEnabled ? new SolidColorBrush(ParseColor(s.PopupBackgroundColor, Colors.White)) : Brushes.White;
        Bezel.BorderBrush = new SolidColorBrush(ParseColor(s.PopupBezelColor, Color.FromRgb(0xE6, 0x97, 0x18)));
        Bezel.BorderThickness = new Thickness(s.PopupBezelEnabled ? Math.Clamp(s.PopupBezelWidth, 0, 12) : 1);
        if (!s.PopupBezelEnabled) Bezel.BorderBrush = (Brush)FindResource("Hairline");
    }

    private static double? GetScaleForScreen(System.Windows.Forms.Screen screen)
    {
        try
        {
            var pt = new Native.POINT { X = screen.Bounds.Left + 1, Y = screen.Bounds.Top + 1 };
            var mon = Native.MonitorFromPoint(pt, 2);
            if (Native.GetDpiForMonitor(mon, 0, out var dx, out _) == 0) return dx / 96.0;
        }
        catch { }
        return null;
    }

    /// <summary>"#RRGGBB" or "#RRGGBBAA" (the Mac app's storage format).</summary>
    public static Color ParseColor(string hex, Color fallback)
    {
        try
        {
            var h = hex.TrimStart('#');
            if (h.Length is not (6 or 8)) return fallback;
            var r = Convert.ToByte(h[..2], 16);
            var g = Convert.ToByte(h[2..4], 16);
            var b = Convert.ToByte(h[4..6], 16);
            var a = h.Length == 8 ? Convert.ToByte(h[6..8], 16) : (byte)255;
            return Color.FromArgb(a, r, g, b);
        }
        catch { return fallback; }
    }

    public static string ToHex(Color c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}{c.A:X2}";

    // MARK: - Results

    private void Rebuild(bool keepSelection = false)
    {
        var selectedKey = keepSelection ? KeyOf(Results.SelectedItem as PopupRow) : null;
        _rows.Clear();
        var q = Search.Text.Trim();
        Placeholder.Visibility = Search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

        if (_collection == null)
        {
            var collections = _host.Snippets.Collections();
            if (q.Length == 0)
            {
                if (collections.Count > 0)
                {
                    _rows.Add(new HeaderRow("Snippets"));
                    foreach (var c in collections) _rows.Add(new CollectionRow(c, _host.Snippets.Snippets(c.Id).Count));
                }
            }
            else
            {
                // Snippets match on name + keyword only, never content.
                var names = collections.ToDictionary(c => c.Id, c => c.Name);
                var lower = q.ToLowerInvariant();
                var matches = _host.Snippets.AllSnippets()
                    .Where(s => s.Name.ToLowerInvariant().Contains(lower) || (s.Keyword?.ToLowerInvariant().Contains(lower) ?? false))
                    .Take(50).ToList();
                if (matches.Count > 0)
                {
                    _rows.Add(new HeaderRow("Snippets"));
                    foreach (var s in matches) _rows.Add(new SnippetRow(s, names.GetValueOrDefault(s.CollectionId, "")));
                }
            }
            _clipsLoaded = 0;
            _hasMoreClips = true;
            _rows.Add(new HeaderRow("Clipboard History"));
            LoadMoreClips();
        }
        else
        {
            _rows.Add(new HeaderRow(_collection.Name, canGoBack: true));
            var lower = q.ToLowerInvariant();
            foreach (var s in _host.Snippets.Snippets(_collection.Id))
                if (q.Length == 0 || s.Name.ToLowerInvariant().Contains(lower) || (s.Keyword?.ToLowerInvariant().Contains(lower) ?? false))
                    _rows.Add(new SnippetRow(s, _collection.Name));
        }

        var restore = selectedKey == null ? null : _rows.FirstOrDefault(r => KeyOf(r) == selectedKey);
        Results.SelectedItem = restore ?? _rows.FirstOrDefault(r => r.Selectable);
        if (Results.SelectedItem != null) Results.ScrollIntoView(Results.SelectedItem);
        else UpdatePreview(null);
    }

    private static string? KeyOf(PopupRow? r) => r switch
    {
        ClipRow c => "c" + c.Item.Id,
        SnippetRow s => "s" + s.Snippet.Id,
        CollectionRow c => "k" + c.Collection.Id,
        _ => null,
    };

    private void LoadMoreClips()
    {
        if (!_hasMoreClips || _collection != null) return;
        var q = Search.Text.Trim();
        var page = q.Length == 0 ? _host.Clips.Page(_clipsLoaded, PageSize) : _host.Clips.Search(q, _clipsLoaded, PageSize);
        foreach (var it in page) _rows.Add(new ClipRow(it));
        _clipsLoaded += page.Count;
        _hasMoreClips = page.Count == PageSize;
    }

    private void ResultsScrolled(object sender, ScrollChangedEventArgs e)
    {
        if (e.VerticalOffset + e.ViewportHeight >= e.ExtentHeight - 120) LoadMoreClips();
    }

    private void SearchChanged(object sender, TextChangedEventArgs e) => Rebuild();

    private void MoveSelection(int delta)
    {
        var idx = Results.SelectedIndex;
        var i = idx;
        while (true)
        {
            i += delta;
            if (i < 0 || i >= _rows.Count) break;
            if (_rows[i].Selectable)
            {
                Results.SelectedIndex = i;
                Results.ScrollIntoView(_rows[i]);
                if (i >= _rows.Count - 5) LoadMoreClips();
                return;
            }
        }
        if (delta > 0) LoadMoreClips();
    }

    // MARK: - Keys

    private void SearchKeyDown(object sender, KeyEventArgs e)
    {
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        switch (e.Key)
        {
            case Key.Down: MoveSelection(1); break;
            case Key.Up: MoveSelection(-1); break;
            case Key.PageDown: MoveSelection(8); break;
            case Key.PageUp: MoveSelection(-8); break;
            case Key.Enter: ActivateRow(Results.SelectedItem as PopupRow, plainText: false); break;
            case Key.Left when Search.CaretIndex == 0 && Search.SelectionLength == 0 && _collection != null: DrillOut(); break;
            case Key.Back when Search.Text.Length == 0 && _collection != null: DrillOut(); break;
            case Key.Right when Search.CaretIndex == Search.Text.Length && Results.SelectedItem is CollectionRow c: DrillIn(c.Collection); break;
            case Key.C when ctrl && Search.SelectionLength == 0: CopyOnly(Results.SelectedItem as PopupRow); break;
            case Key.V when ctrl && shift: ActivateRow(Results.SelectedItem as PopupRow, plainText: true); break;
            default: return;
        }
        e.Handled = true;
    }

    private void WindowKeyDown(object sender, KeyEventArgs e)
    {
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        if (e.Key == Key.Escape) { HidePopup(); e.Handled = true; }
        else if (ctrl && e.Key == Key.OemComma) { HidePopup(restoreFocus: false); _host.OpenSettings(); e.Handled = true; }
        else if (ctrl && e.Key == Key.P && Results.SelectedItem is ClipRow cr) { TogglePin(cr.Item); e.Handled = true; }
        else if (!Search.IsKeyboardFocused && e.Key is not (Key.Up or Key.Down or Key.Enter or Key.Tab))
        {
            // Typing anywhere goes to the search field.
            Search.Focus();
        }
    }

    private void ResultsDoubleClick(object sender, MouseButtonEventArgs e) => ActivateRow(Results.SelectedItem as PopupRow, plainText: false);

    private void BackClicked(object sender, MouseButtonEventArgs e) => DrillOut();

    private void DrillIn(SnippetCollection c)
    {
        _collection = c;
        Search.Text = ""; // triggers Rebuild
        Rebuild();
    }

    private void DrillOut()
    {
        if (_collection == null) return;
        var from = _collection;
        _collection = null;
        Search.Text = "";
        Rebuild();
        var row = _rows.OfType<CollectionRow>().FirstOrDefault(r => r.Collection.Id == from.Id);
        if (row != null) { Results.SelectedItem = row; Results.ScrollIntoView(row); }
    }

    private void ActivateRow(PopupRow? row, bool plainText)
    {
        switch (row)
        {
            case CollectionRow c: DrillIn(c.Collection); break;
            case SnippetRow s:
                HidePopup(restoreFocus: false);
                _host.Paster.PasteText(s.Snippet.Content, _controller.TargetWindow);
                break;
            case ClipRow c:
                var item = Resolved(c.Item);
                HidePopup(restoreFocus: false);
                _host.Paster.Paste(item, _controller.TargetWindow, plainText);
                break;
        }
    }

    private void CopyOnly(PopupRow? row)
    {
        switch (row)
        {
            case SnippetRow s:
                Clipboard.Paster.CopyText(s.Snippet.Content);
                HidePopup();
                break;
            case ClipRow c:
                _host.Paster.Paste(Resolved(c.Item), _controller.TargetWindow, pasteIntoTarget: false);
                HidePopup();
                break;
        }
    }

    /// <summary>Re-reads the row in case another path (fast append) changed it since the list was built.</summary>
    private ClipItem Resolved(ClipItem item) => _host.Clips.Get(item.Id) ?? item;

    // MARK: - Preview

    private void ResultsSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Results.SelectedItem is PopupRow { Selectable: false })
        {
            MoveSelection(1);
            return;
        }
        UpdatePreview(Results.SelectedItem as PopupRow);
    }

    private void UpdatePreview(PopupRow? row)
    {
        PreviewHost.Children.Clear();
        PinButton.Visibility = StarButton.Visibility = DeleteButton.Visibility = Visibility.Collapsed;
        Meta.Text = "";
        switch (row)
        {
            case ClipRow c:
                var item = Resolved(c.Item);
                PinButton.Visibility = StarButton.Visibility = DeleteButton.Visibility = Visibility.Visible;
                StarButton.Visibility = item.Kind == ClipKind.Text ? Visibility.Visible : Visibility.Collapsed;
                PinButton.ToolTip = item.Pinned ? "Unpin (Ctrl+P)" : "Pin (Ctrl+P)";
                PinButton.Foreground = item.Pinned ? (Brush)FindResource("Accent") : (Brush)FindResource("Ink");
                PreviewHost.Children.Add(PreviewFor(item));
                var size = item.Kind == ClipKind.Text ? $" · {item.TextContent?.Length ?? 0:N0} characters" : "";
                Meta.Text = $"{(string.IsNullOrEmpty(item.SourceApp) ? "" : item.SourceApp + " · ")}{item.CreatedAt:g}{size}";
                break;
            case SnippetRow s:
                PreviewHost.Children.Add(TextPreview(s.Snippet.Content));
                Meta.Text = string.IsNullOrEmpty(s.Snippet.Keyword) ? s.Snippet.Name : $"{s.Snippet.Name} · keyword {s.Snippet.Keyword}";
                break;
            case CollectionRow c:
                var names = _host.Snippets.Snippets(c.Collection.Id).Select(x => "• " + x.Name);
                PreviewHost.Children.Add(TextPreview(string.Join("\n", names)));
                Meta.Text = $"{c.Collection.Name} · Enter or → to open";
                break;
        }
    }

    private UIElement PreviewFor(ClipItem item)
    {
        switch (item.Kind)
        {
            case ClipKind.Image when item.ImagePath != null:
                try
                {
                    var bmp = new BitmapImage();
                    bmp.BeginInit();
                    bmp.CacheOption = BitmapCacheOption.OnLoad;
                    bmp.DecodePixelWidth = Math.Min(item.ImageWidth ?? 900, 900);
                    bmp.UriSource = new Uri(_host.Clips.Resolve(item.ImagePath));
                    bmp.EndInit();
                    return new Image { Source = bmp, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, VerticalAlignment = VerticalAlignment.Top };
                }
                catch { return TextPreview("(image file missing)"); }
            case ClipKind.File:
                return TextPreview(item.TextContent ?? "");
            default:
                if (!Settings.PlainTextPreview && item.RichTextPath is { } rp && rp.EndsWith(".rtf", StringComparison.OrdinalIgnoreCase))
                {
                    try
                    {
                        var box = new RichTextBox { IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
                        using var fs = File.OpenRead(_host.Clips.Resolve(rp));
                        new TextRange(box.Document.ContentStart, box.Document.ContentEnd).Load(fs, DataFormats.Rtf);
                        return box;
                    }
                    catch { /* fall through to plain */ }
                }
                return TextPreview(item.TextContent ?? "");
        }
    }

    private static UIElement TextPreview(string text) => new TextBox
    {
        Text = text.Length > 200_000 ? text[..200_000] + "\n…" : text,
        IsReadOnly = true,
        TextWrapping = TextWrapping.Wrap,
        BorderThickness = new Thickness(0),
        Background = Brushes.Transparent,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        VerticalContentAlignment = VerticalAlignment.Top,
        Padding = new Thickness(0),
        FontSize = 13,
    };

    // MARK: - Actions

    private void TogglePin(ClipItem item)
    {
        var fresh = Resolved(item);
        _host.Clips.SetPinned(fresh.Id, !fresh.Pinned);
        Rebuild(keepSelection: true);
    }

    private void PinClicked(object sender, RoutedEventArgs e)
    {
        if (Results.SelectedItem is ClipRow c) TogglePin(c.Item);
        Search.Focus();
    }

    private void DeleteClicked(object sender, RoutedEventArgs e)
    {
        if (Results.SelectedItem is not ClipRow c) return;
        var idx = Results.SelectedIndex;
        _host.Clips.Delete(c.Item.Id);
        Rebuild();
        if (idx < _rows.Count && _rows[Math.Max(0, idx)].Selectable) Results.SelectedIndex = idx;
        Search.Focus();
    }

    private void StarClicked(object sender, RoutedEventArgs e)
    {
        if (Results.SelectedItem is ClipRow { Item.Kind: ClipKind.Text } c) SaveAsSnippet(Resolved(c.Item), null);
        Search.Focus();
    }

    private void SaveAsSnippet(ClipItem item, long? collectionId)
    {
        _modal = true;
        try
        {
            var prompt = new SnippetNamePrompt(_host, item.TextContent ?? "", collectionId) { Owner = this };
            prompt.ShowDialog();
        }
        finally
        {
            _modal = false;
            Activate();
            Search.Focus();
        }
    }

    private void ResultsRightClick(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is not DependencyObject d) return;
        var container = ItemsControl.ContainerFromElement(Results, d) as ListBoxItem;
        if (container?.DataContext is not PopupRow row || !row.Selectable) return;
        Results.SelectedItem = row;
        var menu = new ContextMenu();
        void Add(string header, Action act, string? gesture = null)
        {
            var mi = new MenuItem { Header = header, InputGestureText = gesture ?? "" };
            mi.Click += (_, _) => act();
            menu.Items.Add(mi);
        }
        switch (row)
        {
            case ClipRow c:
                Add("Paste", () => ActivateRow(c, false), "Enter");
                if (c.Item.Kind == ClipKind.Text) Add("Paste as Plain Text", () => ActivateRow(c, true), "Ctrl+Shift+V");
                Add("Copy", () => CopyOnly(c), "Ctrl+C");
                menu.Items.Add(new Separator());
                Add(c.Item.Pinned ? "Unpin" : "Pin", () => TogglePin(c.Item), "Ctrl+P");
                if (c.Item.Kind == ClipKind.Text)
                {
                    var add = new MenuItem { Header = "Add to Collection" };
                    foreach (var col in _host.Snippets.Collections())
                    {
                        var mi = new MenuItem { Header = col.Name };
                        var id = col.Id;
                        mi.Click += (_, _) => SaveAsSnippet(Resolved(c.Item), id);
                        add.Items.Add(mi);
                    }
                    if (add.Items.Count > 0) add.Items.Add(new Separator());
                    var nc = new MenuItem { Header = "New Collection…" };
                    nc.Click += (_, _) => SaveAsSnippet(Resolved(c.Item), -1);
                    add.Items.Add(nc);
                    menu.Items.Add(add);
                }
                menu.Items.Add(new Separator());
                Add("Delete", () => { _host.Clips.Delete(c.Item.Id); Rebuild(); });
                break;
            case SnippetRow s:
                Add("Paste", () => ActivateRow(s, false), "Enter");
                Add("Copy", () => CopyOnly(s), "Ctrl+C");
                Add("Edit in Snippets Manager…", () => { HidePopup(restoreFocus: false); _host.OpenSnippetsManager(); });
                break;
            case CollectionRow c:
                Add("Open", () => DrillIn(c.Collection), "Enter");
                break;
        }
        _modal = true;
        menu.Closed += (_, _) => { _modal = false; };
        menu.IsOpen = true;
        e.Handled = true;
    }

    private void SettingsClicked(object sender, RoutedEventArgs e)
    {
        HidePopup(restoreFocus: false);
        _host.OpenSettings("clipboard");
    }

    private void ManagerClicked(object sender, RoutedEventArgs e)
    {
        HidePopup(restoreFocus: false);
        _host.OpenSnippetsManager();
    }
}
