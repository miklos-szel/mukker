using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Mukker.App.Chime;
using Mukker.App.Editor;
using Mukker.App.Popup;
using Mukker.Core;
using Mukker.Core.Settings;
using Mukker.Core.Translate;

namespace Mukker.App.Settings;

/// <summary>Records a global shortcut. Hotkeys are suspended while it listens so the combo reaches it.</summary>
internal sealed class ShortcutRecorder : Button
{
    private readonly AppHost _host;
    private readonly Func<KeyCombo?> _get;
    private readonly Action<KeyCombo?> _set;
    private bool _recording;

    public ShortcutRecorder(AppHost host, Func<KeyCombo?> get, Action<KeyCombo?> set)
    {
        _host = host;
        _get = get;
        _set = set;
        MinWidth = 170;
        HorizontalContentAlignment = HorizontalAlignment.Center;
        Refresh();
        Click += (_, _) => { if (!_recording) Begin(); };
        PreviewKeyDown += OnKey;
        LostKeyboardFocus += (_, _) => End();
    }

    private void Refresh() => Content = _recording ? "Press a shortcut…" : _get()?.ToString() ?? "Not set";

    private void Begin()
    {
        _recording = true;
        _host.HotKeys.Suspend(true);
        Refresh();
        Focus();
    }

    private void End()
    {
        if (!_recording) return;
        _recording = false;
        _host.HotKeys.Suspend(false);
        Refresh();
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (!_recording) return;
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Escape && Keyboard.Modifiers == ModifierKeys.None) { End(); return; }
        if (key is Key.Back or Key.Delete && Keyboard.Modifiers == ModifierKeys.None) { _set(null); End(); return; }
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) return;
        var mods = KeyModifiers.None;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) mods |= KeyModifiers.Control;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) mods |= KeyModifiers.Alt;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) mods |= KeyModifiers.Shift;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Windows)) mods |= KeyModifiers.Win;
        var combo = new KeyCombo(mods, KeyInterop.VirtualKeyFromKey(key));
        if (!ShortcutSettings.IsAcceptable(combo))
        {
            Content = "Needs Ctrl, Alt or Win";
            return;
        }
        _set(combo);
        End();
    }
}

internal sealed class SettingsWindow : Window
{
    private readonly AppHost _host;
    private readonly TabControl _tabs = new() { Padding = new Thickness(0), BorderThickness = new Thickness(0, 1, 0, 0) };
    private readonly Dictionary<string, TabItem> _byName = new();
    private TextBlock? _hotkeyFailures;
    private TextBlock? _translateStatus;

    public SettingsWindow(AppHost host)
    {
        _host = host;
        Title = "Mukker Settings";
        Width = 700;
        Height = 640;
        MinWidth = 560;
        MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = (Brush)FindResource("Surface");
        Icon = BitmapFrame.Create(new Uri("pack://application:,,,/Mukker;component/Assets/mukker.ico"));

        AddTab("clipboard", "Clipboard", BuildClipboard());
        AddTab("capture", "Capture", BuildCapture());
        AddTab("translate", "Translate", BuildTranslate());
        AddTab("hotkeys", "Hotkeys", BuildHotkeys());
        AddTab("about", "About", BuildAbout());
        Content = _tabs;

        _host.HotKeys.FailuresChanged += RefreshFailures;
        Closed += (_, _) => _host.HotKeys.FailuresChanged -= RefreshFailures;
        PreviewKeyDown += (_, e) => { if (e.Key == Key.W && Keyboard.Modifiers == ModifierKeys.Control) Close(); };
        RefreshFailures();
    }

    public void SelectTab(string? name)
    {
        if (name != null && _byName.TryGetValue(name.ToLowerInvariant(), out var t)) _tabs.SelectedItem = t;
    }

    private void AddTab(string key, string header, UIElement content)
    {
        var tab = new TabItem
        {
            Header = new TextBlock { Text = header, Margin = new Thickness(8, 2, 8, 2) },
            Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(20, 16, 20, 16) },
        };
        _byName[key] = tab;
        _tabs.Items.Add(tab);
    }

    private AppSettings S => _host.Settings.Current;
    private void Save(Action<AppSettings> change) => _host.Settings.Update(change);

    // MARK: - Row helpers

    private static StackPanel Section(StackPanel parent, string title)
    {
        var inner = new StackPanel();
        parent.Children.Add(new GroupBox { Header = title, Content = inner });
        return inner;
    }

    private static Grid Row(StackPanel parent, string label, UIElement control, string? caption = null)
    {
        var g = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(210) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var l = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 12, 0) };
        g.Children.Add(l);
        if (control is FrameworkElement fe && fe.HorizontalAlignment == HorizontalAlignment.Stretch && control is not TextBox) fe.HorizontalAlignment = HorizontalAlignment.Left;
        Grid.SetColumn(control, 1);
        g.Children.Add(control);
        parent.Children.Add(g);
        if (caption != null) Caption(parent, caption);
        return g;
    }

    private static void Caption(StackPanel parent, string text) =>
        parent.Children.Add(new TextBlock { Text = text, Style = (Style)Application.Current.FindResource("Caption"), Margin = new Thickness(0, 0, 0, 6) });

    private CheckBox Toggle(StackPanel parent, string label, Func<AppSettings, bool> get, Action<AppSettings, bool> set, string? caption = null)
    {
        var cb = new CheckBox { Content = label, IsChecked = get(S), Margin = new Thickness(0, 5, 0, 5) };
        cb.Click += (_, _) => Save(s => set(s, cb.IsChecked == true));
        parent.Children.Add(cb);
        if (caption != null) Caption(parent, caption);
        return cb;
    }

    private ComboBox Choice<T>(StackPanel parent, string label, (T Value, string Text)[] items, Func<AppSettings, T> get, Action<AppSettings, T> set, string? caption = null)
    {
        var combo = new ComboBox { MinWidth = 200 };
        foreach (var (_, text) in items) combo.Items.Add(text);
        var current = get(S);
        combo.SelectedIndex = Math.Max(0, Array.FindIndex(items, i => EqualityComparer<T>.Default.Equals(i.Value, current)));
        combo.SelectionChanged += (_, _) => { if (combo.SelectedIndex >= 0) Save(s => set(s, items[combo.SelectedIndex].Value)); };
        Row(parent, label, combo, caption);
        return combo;
    }

    private Slider SliderRow(StackPanel parent, string label, double min, double max, double step, Func<AppSettings, double> get, Action<AppSettings, double> set, Func<double, string> format)
    {
        var slider = new Slider { Minimum = min, Maximum = max, TickFrequency = step, IsSnapToTickEnabled = true, Width = 220, Value = get(S), VerticalAlignment = VerticalAlignment.Center };
        var value = new TextBlock { Text = format(slider.Value), Width = 60, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        slider.ValueChanged += (_, _) => value.Text = format(slider.Value);
        slider.PreviewMouseUp += (_, _) => Save(s => set(s, slider.Value));
        slider.LostKeyboardFocus += (_, _) => Save(s => set(s, slider.Value));
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        panel.Children.Add(slider);
        panel.Children.Add(value);
        Row(parent, label, panel);
        return slider;
    }

    private TextBox TextRow(StackPanel parent, string label, Func<AppSettings, string> get, Action<AppSettings, string> set, string? caption = null, Action<string>? changed = null)
    {
        var box = new TextBox { Text = get(S), MinWidth = 260 };
        box.LostKeyboardFocus += (_, _) => Save(s => set(s, box.Text));
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) Save(s => set(s, box.Text)); };
        if (changed != null) box.TextChanged += (_, _) => changed(box.Text);
        Row(parent, label, box, caption);
        return box;
    }

    private void ColorRow(StackPanel parent, string label, Func<AppSettings, string> get, Action<AppSettings, string> set)
    {
        var swatch = new Border { Width = 28, Height = 20, CornerRadius = new CornerRadius(4), BorderBrush = Brushes.Gray, BorderThickness = new Thickness(1), VerticalAlignment = VerticalAlignment.Center };
        void Paint() => swatch.Background = new SolidColorBrush(PopupWindow.ParseColor(get(S), Colors.White));
        Paint();
        var pick = new Button { Content = "Choose…", Margin = new Thickness(10, 0, 0, 0) };
        pick.Click += (_, _) =>
        {
            var c = PopupWindow.ParseColor(get(S), Colors.White);
            using var dlg = new System.Windows.Forms.ColorDialog { FullOpen = true, Color = System.Drawing.Color.FromArgb(c.R, c.G, c.B) };
            if (dlg.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
            var picked = Color.FromArgb(255, dlg.Color.R, dlg.Color.G, dlg.Color.B);
            Save(s => set(s, PopupWindow.ToHex(picked)));
            Paint();
        };
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        panel.Children.Add(swatch);
        panel.Children.Add(pick);
        Row(parent, label, panel);
    }

    private void FolderRow(StackPanel parent, string label, Func<AppSettings, string?> get, Action<AppSettings, string?> set, string fallback)
    {
        var text = new TextBlock { Text = get(S) ?? fallback, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 260 };
        var choose = new Button { Content = "Choose…", Margin = new Thickness(10, 0, 0, 0) };
        choose.Click += (_, _) =>
        {
            using var dlg = new System.Windows.Forms.FolderBrowserDialog { SelectedPath = get(S) ?? fallback, UseDescriptionForTitle = true, Description = label };
            if (dlg.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
            Save(s => set(s, dlg.SelectedPath));
            text.Text = dlg.SelectedPath;
        };
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        panel.Children.Add(text);
        panel.Children.Add(choose);
        Row(parent, label, panel);
    }

    private void ShortcutRow(StackPanel parent, string label, Func<ShortcutSettings, KeyCombo?> get, Action<ShortcutSettings, KeyCombo?> set) =>
        Row(parent, label, new ShortcutRecorder(_host, () => get(S.Shortcuts), c => Save(s => set(s.Shortcuts, c))));

    private static readonly (Retention, string)[] Retentions =
        [(Retention.Day, "1 day"), (Retention.Week, "1 week"), (Retention.Month, "1 month"), (Retention.ThreeMonths, "3 months"), (Retention.Year, "1 year"), (Retention.Forever, "Forever")];

    // MARK: - Tabs

    private UIElement BuildClipboard()
    {
        var root = new StackPanel();
        var h = Section(root, "History");
        Toggle(h, "Keep text", s => s.Clipboard.KeepText, (s, v) => s.Clipboard.KeepText = v);
        Choice(h, "Keep text for", Retentions, s => s.Clipboard.TextRetention, (s, v) => s.Clipboard.TextRetention = v);
        Toggle(h, "Keep images", s => s.Clipboard.KeepImages, (s, v) => s.Clipboard.KeepImages = v);
        Choice(h, "Keep images for", Retentions, s => s.Clipboard.ImageRetention, (s, v) => s.Clipboard.ImageRetention = v);
        Toggle(h, "Keep file lists", s => s.Clipboard.KeepFiles, (s, v) => s.Clipboard.KeepFiles = v);
        Choice(h, "Keep file lists for", Retentions, s => s.Clipboard.FileRetention, (s, v) => s.Clipboard.FileRetention = v);
        Choice(h, "Maximum items", new[] { 100, 250, 500, 1000, 2000, 5000, 10000 }.Select(n => (n, n.ToString("N0"))).ToArray(),
            s => s.Clipboard.MaxHistoryItems, (s, v) => s.Clipboard.MaxHistoryItems = v, "The oldest unpinned items are removed first.");
        Toggle(h, "Move an item to the top when it is used or copied again", s => s.Clipboard.MoveToTopOnUse, (s, v) => s.Clipboard.MoveToTopOnUse = v);
        Toggle(h, "Paste into the previous app (otherwise only copy)", s => s.Clipboard.AutoPasteEnabled, (s, v) => s.Clipboard.AutoPasteEnabled = v);
        Toggle(h, "Show formatted text as plain text in the preview", s => s.Clipboard.PlainTextPreview, (s, v) => s.Clipboard.PlainTextPreview = v);
        var clear = new Button { Content = "Clear History…", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) };
        clear.Click += (_, _) =>
        {
            if (MessageBox.Show(this, "Delete every unpinned item from the clipboard history? Pinned items are kept.", "Clear History",
                    MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK)
                _host.Clips.ClearUnpinned();
        };
        h.Children.Add(clear);

        var p = Section(root, "Popup");
        SliderRow(p, "Size (share of the screen)", 0.3, 0.9, 0.05, s => s.Clipboard.PopupSizePercent, (s, v) => s.Clipboard.PopupSizePercent = v, v => $"{v:P0}");
        Toggle(p, "Custom background colour", s => s.Clipboard.PopupCustomBackgroundEnabled, (s, v) => s.Clipboard.PopupCustomBackgroundEnabled = v);
        ColorRow(p, "Background", s => s.Clipboard.PopupBackgroundColor, (s, v) => s.Clipboard.PopupBackgroundColor = v);
        Toggle(p, "Coloured bezel", s => s.Clipboard.PopupBezelEnabled, (s, v) => s.Clipboard.PopupBezelEnabled = v);
        ColorRow(p, "Bezel colour", s => s.Clipboard.PopupBezelColor, (s, v) => s.Clipboard.PopupBezelColor = v);
        SliderRow(p, "Bezel width", 0, 12, 1, s => s.Clipboard.PopupBezelWidth, (s, v) => s.Clipboard.PopupBezelWidth = v, v => $"{v:0} px");

        var m = Section(root, "Merging");
        Toggle(m, "Fast append: press Ctrl+C twice to append to the previous text", s => s.Clipboard.FastAppendEnabled, (s, v) => s.Clipboard.FastAppendEnabled = v);
        Toggle(m, "Put the merged text back on the clipboard", s => s.Clipboard.FastAppendBackToClipboard, (s, v) => s.Clipboard.FastAppendBackToClipboard = v);
        Choice(m, "Separator", new[] { (AppendSeparator.None, "None"), (AppendSeparator.Space, "Space"), (AppendSeparator.Newline, "New line") },
            s => s.Clipboard.AppendSeparator, (s, v) => s.Clipboard.AppendSeparator = v);
        Toggle(m, "Play a sound when text is appended", s => s.Clipboard.PlayAppendSound, (s, v) => s.Clipboard.PlayAppendSound = v);

        var a = Section(root, "Advanced");
        Choice(a, "Maximum clip size", new[] { (MaxClipSize.K64, "64 KB"), (MaxClipSize.K256, "256 KB"), (MaxClipSize.K512, "512 KB"), (MaxClipSize.M1, "1 MB"), (MaxClipSize.M2, "2 MB"), (MaxClipSize.Unlimited, "Unlimited") },
            s => s.Clipboard.MaxClipSize, (s, v) => s.Clipboard.MaxClipSize = v);
        Toggle(a, "Ignore items marked as sensitive", s => s.Clipboard.IgnoreConcealedItems, (s, v) => s.Clipboard.IgnoreConcealedItems = v,
            "Skips copies that apps exclude from clipboard history (password managers do), and copies from the password-manager browser extensions.");
        var ignored = new TextBox
        {
            Text = string.Join(Environment.NewLine, S.Clipboard.IgnoredApps.Select(x => x.ProcessName)),
            AcceptsReturn = true, Height = 110, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalContentAlignment = VerticalAlignment.Top,
            FontFamily = (FontFamily)FindResource("MonoFont"),
        };
        ignored.LostKeyboardFocus += (_, _) => Save(s => s.Clipboard.IgnoredApps = ignored.Text
            .Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(n => new IgnoredApp { ProcessName = System.IO.Path.GetFileNameWithoutExtension(n), DisplayName = n }).ToList());
        Row(a, "Ignored apps (process names, one per line)", ignored, "Copies made in these apps are never recorded.");
        Toggle(a, "Forever history: archive text items as .txt files before they are deleted", s => s.Clipboard.ForeverHistoryEnabled, (s, v) => s.Clipboard.ForeverHistoryEnabled = v);
        FolderRow(a, "Archive folder", s => s.Clipboard.ForeverHistoryDirectory, (s, v) => s.Clipboard.ForeverHistoryDirectory = v, AppPaths.DefaultForeverHistoryDirectory);
        return root;
    }

    private static readonly (int, string)[] PaletteChoices = Palette.Colors.Select((c, i) => (i, c.Name)).ToArray();

    private UIElement BuildCapture()
    {
        var root = new StackPanel();
        var o = Section(root, "After capture");
        Choice(o, "When a capture is taken", new[] { (AfterCapture.Show, "Open the editor"), (AfterCapture.Copy, "Copy to the clipboard"), (AfterCapture.Save, "Save to the folder") },
            s => s.Capture.AfterCapture, (s, v) => s.Capture.AfterCapture = v);
        FolderRow(o, "Save folder", s => s.Capture.SaveDirectory, (s, v) => s.Capture.SaveDirectory = v, Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory));
        Choice(o, "Format", new[] { (SaveFormat.Png, "PNG"), (SaveFormat.Jpeg, "JPEG (90%)") }, s => s.Capture.SaveFormat, (s, v) => s.Capture.SaveFormat = v);
        Toggle(o, "Downscale to 100% scale", s => s.Capture.DownscaleToStandard, (s, v) => s.Capture.DownscaleToStandard = v,
            "On a display scaled above 100%, exports at the size things appear rather than in physical pixels.");
        Toggle(o, "Show a magnifier while selecting", s => s.Capture.ShowMagnifierDuringCapture, (s, v) => s.Capture.ShowMagnifierDuringCapture = v);

        var e = Section(root, "Editor");
        Toggle(e, "Close the editor after copying", s => s.Capture.CloseAfterCopy, (s, v) => s.Capture.CloseAfterCopy = v);
        Toggle(e, "Close the editor after saving", s => s.Capture.CloseAfterSave, (s, v) => s.Capture.CloseAfterSave = v);
        Toggle(e, "Esc copies and closes (when nothing else is left to cancel)", s => s.Capture.EscCopiesAndCloses, (s, v) => s.Capture.EscCopiesAndCloses = v);
        Choice(e, "Default colour", PaletteChoices, s => s.Capture.DefaultColorIndex, (s, v) => s.Capture.DefaultColorIndex = v);
        Choice(e, "Default text colour", PaletteChoices, s => s.Capture.DefaultTextColorIndex, (s, v) => s.Capture.DefaultTextColorIndex = v);
        SliderRow(e, "Default line width", 1, 20, 1, s => s.Capture.DefaultLineWidth, (s, v) => s.Capture.DefaultLineWidth = v, v => $"{v:0} px");
        SliderRow(e, "Default text size", 10, 96, 1, s => s.Capture.DefaultTextSize, (s, v) => s.Capture.DefaultTextSize = v, v => $"{v:0} px");
        Caption(e, "Tool keys: V select, M hand, A arrow, L line, O rectangle, R rounded rectangle, E ellipse, P pen, T text, N counter, H highlight, B blur, C crop.");

        var sc = Section(root, "Scrolling capture");
        Choice(sc, "Maximum height", new[] { 5000, 10000, 20000, 40000 }.Select(n => (n, $"{n:N0} px")).ToArray(), s => s.Capture.ScrollMaxHeight, (s, v) => s.Capture.ScrollMaxHeight = v);
        SliderRow(sc, "Speed", 0, 1, 0.1, s => s.Capture.ScrollSpeed, (s, v) => s.Capture.ScrollSpeed = v, v => $"{v:P0}");
        Caption(sc, "Select the area, then Mukker scrolls it and stitches the frames. Press Esc to stop early. Sticky headers can show up repeated.");
        return root;
    }

    /// <summary>The hourly chime — what is left of the Mac calendar feature; Windows has its own calendar.</summary>
    private void BuildChime(StackPanel root)
    {
        var c = Section(root, "Hourly chime");
        Toggle(c, "Play a sound at the top of every hour", s => s.Chime.HourlyChime, (s, v) => s.Chime.HourlyChime = v);
        var sounds = ChimeService.AvailableSounds();
        if (sounds.Length == 0) sounds = new[] { S.Chime.HourlyChimeSound };
        var soundCombo = Choice(c, "Sound", sounds.Select(n => (n, n)).ToArray(), s => s.Chime.HourlyChimeSound, (s, v) => s.Chime.HourlyChimeSound = v);
        var test = new Button { Content = "Test", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 2, 0, 6) };
        test.Click += (_, _) => _host.Chime.Play(soundCombo.SelectedItem as string);
        Row(c, "", test);
        var hours = Enumerable.Range(0, 24).Select(h => (h, $"{h:00}:00")).ToArray();
        Choice(c, "From", hours, s => s.Chime.HourlyChimeStartHour, (s, v) => s.Chime.HourlyChimeStartHour = v);
        Choice(c, "Until", hours, s => s.Chime.HourlyChimeEndHour, (s, v) => s.Chime.HourlyChimeEndHour = v,
            "Both hours included. A range that ends before it starts runs past midnight.");
    }

    private UIElement BuildTranslate()
    {
        var root = new StackPanel();
        var g = Section(root, "Translate");
        Toggle(g, "Enable translation shortcuts", s => s.Translation.Enabled, (s, v) => s.Translation.Enabled = v,
            "Translates the selected text, or with nothing selected the newest clipboard item, and shows it in a panel.");
        ShortcutRow(g, "Translate to English", s => s.TranslateEnglish, (s, v) => s.TranslateEnglish = v);
        ShortcutRow(g, "Translate to Hungarian", s => s.TranslateHungarian, (s, v) => s.TranslateHungarian = v);
        Toggle(g, "Copy the translation to the clipboard", s => s.Translation.CopiesResult, (s, v) => s.Translation.CopiesResult = v);

        var b = Section(root, "Translate with");
        var footer = new TextBlock { Style = (Style)FindResource("Caption"), Margin = new Thickness(0, 6, 0, 0) };
        _translateStatus = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 4) };
        TextBox? path = null, model = null;
        void Refresh()
        {
            var backend = S.Translation.Backend;
            if (path != null) path.Text = S.Translation.PathFor(backend);
            if (model != null) model.Text = S.Translation.ModelFor(backend);
            var found = new CliLocator().Resolve(backend, S.Translation.PathFor(backend));
            _translateStatus.Text = found != null ? $"Found at {found.DisplayPath}" : TranslationErrors.NotFound(backend);
            _translateStatus.Foreground = found != null ? (Brush)FindResource("InkSoft") : (Brush)FindResource("Danger");
            footer.Text = $"The text is sent to {backend.Provider()} through the {backend.ExecutableName()} command-line tool, signed in with your own subscription. No API key is stored in Mukker.";
        }
        Choice(b, "Service", new[] { (TranslationBackend.Codex, TranslationBackend.Codex.Label()), (TranslationBackend.Claude, TranslationBackend.Claude.Label()) },
            s => s.Translation.Backend, (s, v) => s.Translation.Backend = v).SelectionChanged += (_, _) => Dispatcher.BeginInvoke(Refresh);
        void SetPath(AppSettings s, string v)
        {
            if (s.Translation.Backend == TranslationBackend.Codex) s.Translation.CodexPath = v.Trim(); else s.Translation.ClaudePath = v.Trim();
        }
        path = TextRow(b, "Path", s => s.Translation.PathFor(s.Translation.Backend), SetPath, "Leave empty to auto-detect.");
        path.LostKeyboardFocus += (_, _) => Dispatcher.BeginInvoke(Refresh);

        // Browse… picks the executable by hand; Find lists every copy in the usual install locations.
        var browse = new Button { Content = "Browse…", Margin = new Thickness(0, 0, 6, 0) };
        var find = new Button { Content = "Find", Margin = new Thickness(0, 0, 6, 0), ToolTip = "Search npm, the native installer, WinGet, Scoop, pnpm, Volta, Bun and PATH" };
        var auto = new Button { Content = "Auto-detect", ToolTip = "Clear the path and find it automatically" };
        void Use(string p)
        {
            Save(s => SetPath(s, p));
            Refresh();
        }
        browse.Click += (_, _) =>
        {
            var backend = S.Translation.Backend;
            var current = new CliLocator().Resolve(backend, S.Translation.PathFor(backend))?.DisplayPath;
            var dlg = new Microsoft.Win32.OpenFileDialog
            {
                Title = $"Choose the {backend.ExecutableName()} executable",
                Filter = $"{backend.ExecutableName()} (*.exe;*.cmd)|*.exe;*.cmd|All files (*.*)|*.*",
                FileName = backend.ExecutableName(),
                InitialDirectory = current != null ? System.IO.Path.GetDirectoryName(current)
                    : System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin"),
            };
            if (dlg.ShowDialog(this) == true) Use(dlg.FileName);
        };
        find.Click += (_, _) =>
        {
            var backend = S.Translation.Backend;
            var all = new CliLocator().FindAll(backend);
            if (all.Count == 0)
            {
                MessageBox.Show(this, TranslationErrors.NotFound(backend), "Not found", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            var menu = new ContextMenu { PlacementTarget = find, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
            foreach (var r in all)
            {
                var item = new MenuItem { Header = r.DisplayPath, IsChecked = string.Equals(r.DisplayPath, S.Translation.PathFor(backend), StringComparison.OrdinalIgnoreCase) };
                var chosen = r.DisplayPath;
                item.Click += (_, _) => Use(chosen);
                menu.Items.Add(item);
            }
            menu.IsOpen = true;
        };
        auto.Click += (_, _) => Use("");
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 4) };
        tools.Children.Add(browse);
        tools.Children.Add(find);
        tools.Children.Add(auto);
        Row(b, "", tools);
        model = TextRow(b, "Model", s => s.Translation.ModelFor(s.Translation.Backend), (s, v) =>
        {
            if (s.Translation.Backend == TranslationBackend.Codex) s.Translation.CodexModel = v.Trim(); else s.Translation.ClaudeModel = v.Trim();
        }, "Empty uses the CLI's default model.");
        b.Children.Add(_translateStatus);
        b.Children.Add(footer);
        Refresh();
        return root;
    }

    private UIElement BuildHotkeys()
    {
        var root = new StackPanel();
        var g = Section(root, "Global shortcuts");
        ShortcutRow(g, "Clipboard & snippets popup", s => s.Popup, (s, v) => s.Popup = v);
        ShortcutRow(g, "Capture area", s => s.Area, (s, v) => s.Area = v);
        ShortcutRow(g, "Capture fullscreen", s => s.Fullscreen, (s, v) => s.Fullscreen = v);
        ShortcutRow(g, "Scrolling capture", s => s.Scrolling, (s, v) => s.Scrolling = v);
        Caption(g, "Click a shortcut, then press the new combination. Backspace clears it, Esc cancels. The translate shortcuts are on the Translate tab.");
        _hotkeyFailures = new TextBlock { Foreground = (Brush)FindResource("Danger"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
        g.Children.Add(_hotkeyFailures);
        var reset = new Button { Content = "Reset All", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 10, 0, 0) };
        reset.Click += (_, _) =>
        {
            Save(s => s.Shortcuts = ShortcutSettings.Defaults());
            var selected = _tabs.SelectedIndex;
            _tabs.Items.Clear();
            _byName.Clear();
            AddTab("clipboard", "Clipboard", BuildClipboard());
            AddTab("capture", "Capture", BuildCapture());
                AddTab("translate", "Translate", BuildTranslate());
            AddTab("hotkeys", "Hotkeys", BuildHotkeys());
            AddTab("about", "About", BuildAbout());
            _tabs.SelectedIndex = selected;
            RefreshFailures();
        };
        g.Children.Add(reset);
        return root;
    }

    private void RefreshFailures()
    {
        if (_hotkeyFailures == null) return;
        var f = _host.HotKeys.Failures;
        _hotkeyFailures.Text = f.Count == 0 ? "" : $"Already used by another app, not registered: {string.Join(", ", f)}. Pick a different combination.";
    }

    private UIElement BuildAbout()
    {
        var root = new StackPanel();
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "?";
        root.Children.Add(new Image { Source = BitmapFrame.Create(new Uri("pack://application:,,,/Mukker;component/Assets/mukker.ico")), Width = 64, Height = 64, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 0, 0, 8) });
        root.Children.Add(new TextBlock { Text = "Mukker for Windows", FontSize = 20, FontWeight = FontWeights.SemiBold });
        root.Children.Add(new TextBlock { Text = $"Version {version}", Foreground = (Brush)FindResource("InkSoft"), Margin = new Thickness(0, 2, 0, 12) });
        root.Children.Add(new TextBlock { Text = "Clipboard history and snippets, screen capture with annotation, and translation — in the notification area.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 14) });
        var g = Section(root, "General");
        Toggle(g, "Start Mukker when you sign in to Windows", s => s.StartWithWindows, (s, v) => s.StartWithWindows = v);
        var open = new Button { Content = "Open Data Folder", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0) };
        open.Click += (_, _) => Process.Start(new ProcessStartInfo("explorer.exe", $"\"{_host.Paths.DataDirectory}\"") { UseShellExecute = true });
        g.Children.Add(open);
        Caption(g, $"History and snippets: {_host.Paths.DatabasePath}\nSettings: {_host.Paths.SettingsPath}");
        BuildChime(root);
        return root;
    }
}
