using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;
using Mukker.App.Dictation.Engine;
using Mukker.Core.Settings;
using Mukker.Core.Translate;

namespace Mukker.App.Tray;

/// <summary>
/// The notification-area icon: the Mukker app icon. Left click opens the actions menu (translate, the clipboard
/// popup, capture); right click opens the management menu (Snippets Manager, Clear History, Settings, Quit). Both menus are rebuilt on every open, so shortcut hints and
/// the translate switch are never stale. There is no calendar — Windows has its own in the taskbar clock.
/// </summary>
internal sealed class TrayController : IDisposable
{
    private static readonly Uri IconUri = new("pack://application:,,,/Mukker;component/Assets/mukker.ico");

    private readonly AppHost _host;
    private readonly NotifyIcon _icon;
    private readonly ContextMenuStrip _settingsMenu;
    private Icon? _current;
    private bool _recording;

    public TrayController(AppHost host)
    {
        _host = host;
        _settingsMenu = NewMenu();
        _settingsMenu.Opening += (_, _) => FillSettingsMenu(_settingsMenu);
        FillSettingsMenu(_settingsMenu);
        _icon = new NotifyIcon { Visible = true, Text = "Mukker", ContextMenuStrip = _settingsMenu };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) ShowActionsMenu();
        };
        SystemEvents.UserPreferenceChanged += OnPreferenceChanged;
        SystemEvents.DisplaySettingsChanged += OnDisplayChanged;
        Refresh();
    }

    private void OnPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color or UserPreferenceCategory.Desktop)
            System.Windows.Application.Current.Dispatcher.BeginInvoke(Refresh);
    }

    private void OnDisplayChanged(object? sender, EventArgs e) => System.Windows.Application.Current.Dispatcher.BeginInvoke(Refresh);

    /// <summary>Reloads the icon at the current small-icon size, so the .ico's matching frame is used rather than a scaled one.</summary>
    public void Refresh()
    {
        var icon = LoadIcon(SystemInformation.SmallIconSize);
        if (icon == null) return;
        if (_recording && WithRecordingDot(icon) is { } dotted)
        {
            icon.Dispose();
            icon = dotted;
        }
        _icon.Icon = icon;
        _current?.Dispose();
        _current = icon;
    }

    /// <summary>Dictation is recording: the icon gets a red dot in its corner until it stops.</summary>
    public void SetRecording(bool recording)
    {
        if (_recording == recording) return;
        _recording = recording;
        _icon.Text = recording ? "Mukker — recording" : "Mukker";
        Refresh();
    }

    /// <summary>A copy of <paramref name="icon"/> with a red dot (white rim) bottom-right, at the icon's own size.</summary>
    private static Icon? WithRecordingDot(Icon icon)
    {
        try
        {
            using var bitmap = icon.ToBitmap();
            using (var g = Graphics.FromImage(bitmap))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                var d = Math.Max(6, bitmap.Width * 5 / 11f);
                var r = new RectangleF(bitmap.Width - d - 0.5f, bitmap.Height - d - 0.5f, d, d);
                using var rim = new SolidBrush(Color.White);
                using var fill = new SolidBrush(Color.FromArgb(230, 32, 32));
                g.FillEllipse(rim, r);
                r.Inflate(-1f, -1f);
                g.FillEllipse(fill, r);
            }
            var handle = bitmap.GetHicon();
            try { return (Icon)Icon.FromHandle(handle).Clone(); }
            finally { Mukker.App.Interop.Native.DestroyIcon(handle); }
        }
        catch (Exception e)
        {
            AppHost.Log($"tray recording icon: {e.Message}");
            return null;
        }
    }

    private static Icon? LoadIcon(Size size)
    {
        try
        {
            using var stream = System.Windows.Application.GetResourceStream(IconUri)?.Stream;
            return stream == null ? null : new Icon(stream, size);
        }
        catch (Exception e)
        {
            AppHost.Log($"tray icon: {e.Message}");
            return null;
        }
    }

    private static ContextMenuStrip NewMenu() => new() { ShowImageMargin = false, Font = new Font("Segoe UI", 9f) };

    /// <summary>The left-click menu: the things Mukker does.</summary>
    public void ShowActionsMenu()
    {
        var menu = NewMenu();
        FillActionsMenu(menu);
        menu.Closed += (_, _) =>
        {
            _icon.ContextMenuStrip = _settingsMenu;
            menu.BeginInvoke(menu.Dispose);
        };
        ShowFromIcon(menu);
    }

    /// <summary>The right-click menu, opened programmatically (debug hook).</summary>
    public void ShowSettingsMenu()
    {
        FillSettingsMenu(_settingsMenu);
        ShowFromIcon(_settingsMenu);
    }

    /// <summary>
    /// Shows <paramref name="menu"/> the way NotifyIcon shows its own context menu: it first makes its hidden
    /// window foreground, which is what lets a click elsewhere dismiss the menu. A plain <c>Show()</c> skips
    /// that and leaves the menu stuck open. Falls back to <c>Show</c> at the cursor if the internals change.
    /// </summary>
    private void ShowFromIcon(ContextMenuStrip menu)
    {
        _icon.ContextMenuStrip = menu;
        var show = typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic);
        try
        {
            if (show != null)
            {
                show.Invoke(_icon, null);
                return;
            }
        }
        catch (Exception e) { AppHost.Log($"tray menu: {e.Message}"); }
        menu.Show(Cursor.Position);
    }

    private void FillActionsMenu(ContextMenuStrip menu)
    {
        var s = _host.Settings.Current;
        string Keys(KeyCombo? c) => c?.ToString() ?? "";
        menu.Items.Clear();

        if (s.Translation.Enabled)
        {
            menu.Items.Add(new ToolStripMenuItem("Translate to English", null, (_, _) => _host.Translation.Request(TranslationLanguage.English)) { ShortcutKeyDisplayString = Keys(s.Shortcuts.TranslateEnglish) });
            menu.Items.Add(new ToolStripMenuItem("Translate to Hungarian", null, (_, _) => _host.Translation.Request(TranslationLanguage.Hungarian)) { ShortcutKeyDisplayString = Keys(s.Shortcuts.TranslateHungarian) });
            menu.Items.Add(new ToolStripMenuItem("Translate to German", null, (_, _) => _host.Translation.Request(TranslationLanguage.German)) { ShortcutKeyDisplayString = Keys(s.Shortcuts.TranslateGerman) });
            menu.Items.Add(new ToolStripSeparator());
        }

        if (s.Dictation.Enabled)
        {
            var model = s.Dictation.Model;
            if (!TranscriptionEngine.IsSupported)
                menu.Items.Add(new ToolStripMenuItem("Dictation needs the x64 build") { Enabled = false });
            else if (!_host.DictationStore.IsInstalled(model))
                menu.Items.Add(new ToolStripMenuItem($"Download {model.Name}", null, (_, _) =>
                {
                    _host.DictationStore.Download(model);
                    _host.OpenSettings("dictation");
                }));
            else
                menu.Items.Add(new ToolStripMenuItem(_host.DictationSvc.IsRecording ? "Stop Dictation" : "Start Dictation", null, (_, _) => _host.DictationSvc.ToggleFromMenu())
                {
                    ShortcutKeyDisplayString = s.Dictation.Trigger == DictationTrigger.CtrlWin ? "Ctrl+Win" : Keys(s.Dictation.Combo),
                });
            menu.Items.Add(new ToolStripMenuItem("Dictation Settings…", null, (_, _) => _host.OpenSettings("dictation")));
            menu.Items.Add(new ToolStripSeparator());
        }

        menu.Items.Add(new ToolStripMenuItem("Clipboard && Snippets", null, (_, _) => _host.Popup.Show()) { ShortcutKeyDisplayString = Keys(s.Shortcuts.Popup) });
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add(new ToolStripMenuItem("Capture Area", null, (_, _) => _host.Capture.CaptureArea()) { ShortcutKeyDisplayString = Keys(s.Shortcuts.Area) });
        menu.Items.Add(new ToolStripMenuItem("Capture Fullscreen", null, (_, _) => _host.Capture.CaptureFullscreen()) { ShortcutKeyDisplayString = Keys(s.Shortcuts.Fullscreen) });
        menu.Items.Add(new ToolStripMenuItem("Scrolling Capture", null, (_, _) => _host.Capture.CaptureScrolling()) { ShortcutKeyDisplayString = Keys(s.Shortcuts.Scrolling) });
    }

    private void FillSettingsMenu(ContextMenuStrip menu)
    {
        menu.Items.Clear();
        menu.Items.Add(new ToolStripMenuItem("Snippets Manager…", null, (_, _) => _host.OpenSnippetsManager()));
        menu.Items.Add(new ToolStripMenuItem("Clear History…", null, (_, _) => ClearHistory()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Settings…", null, (_, _) => _host.OpenSettings()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Quit Mukker", null, (_, _) => _host.Quit()));
    }

    private void ClearHistory()
    {
        var r = System.Windows.MessageBox.Show("Delete every unpinned item from the clipboard history? Pinned items are kept.",
            "Clear History", System.Windows.MessageBoxButton.OKCancel, System.Windows.MessageBoxImage.Warning);
        if (r == System.Windows.MessageBoxResult.OK) _host.Clips.ClearUnpinned();
    }

    public void Dispose()
    {
        SystemEvents.UserPreferenceChanged -= OnPreferenceChanged;
        SystemEvents.DisplaySettingsChanged -= OnDisplayChanged;
        _icon.Visible = false;
        _icon.Dispose();
        _settingsMenu.Dispose();
        _current?.Dispose();
    }
}
