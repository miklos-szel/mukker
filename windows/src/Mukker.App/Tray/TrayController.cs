using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Windows.Forms;
using System.Windows.Threading;
using Microsoft.Win32;
using Mukker.App.Calendar;
using Mukker.App.Interop;
using Mukker.Core.Calendar;
using Mukker.Core.Settings;
using Mukker.Core.Translate;

namespace Mukker.App.Tray;

/// <summary>
/// The notification-area icon *is* the date: a calendar page with today's day number knocked out.
/// Left click opens the month calendar; right click opens the menu.
/// </summary>
internal sealed class TrayController : IDisposable
{
    private readonly AppHost _host;
    private readonly NotifyIcon _icon;
    private readonly DispatcherTimer _midnight = new();
    private Icon? _current;
    private CalendarFlyout? _flyout;
    private DateTime _flyoutClosedAt = DateTime.MinValue;

    public TrayController(AppHost host)
    {
        _host = host;
        _icon = new NotifyIcon { Visible = true };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) ToggleCalendar();
        };
        _icon.ContextMenuStrip = BuildMenu();
        _icon.ContextMenuStrip.Opening += (_, _) => _icon.ContextMenuStrip = BuildMenu();
        _midnight.Tick += (_, _) => Refresh();
        SystemEvents.UserPreferenceChanged += OnPreferenceChanged;
        Refresh();
    }

    private void OnPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color)
            System.Windows.Application.Current.Dispatcher.BeginInvoke(Refresh);
    }

    /// <summary>Redraws the icon and tooltip and re-arms the midnight timer (an absolute deadline, never a per-second poll).</summary>
    public void Refresh()
    {
        var now = DateTime.Now;
        var newIcon = RenderIcon(now.Day, TaskbarIsLight());
        _icon.Icon = newIcon;
        _current?.Dispose();
        _current = newIcon;
        var cal = _host.Settings.Current.Calendar;
        var tip = $"Mukker — {DateLabelFormatter.Format(now, cal.TooltipFormat, cal.CustomDateFormat)}";
        _icon.Text = tip.Length > 127 ? tip[..127] : tip;
        _midnight.Stop();
        _midnight.Interval = ChimeSchedule.UntilMidnight(now);
        _midnight.Start();
    }

    private static bool TaskbarIsLight()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return k?.GetValue("SystemUsesLightTheme") is int v && v == 1;
        }
        catch { return false; }
    }

    /// <summary>A filled rounded page with the day number cut out of it, sized for the current DPI.</summary>
    internal static Icon RenderIcon(int day, bool lightTaskbar)
    {
        var size = Math.Max(16, SystemInformation.SmallIconSize.Width);
        var fg = lightTaskbar ? Color.FromArgb(255, 28, 28, 30) : Color.White;
        using var page = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var mask = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        var inset = Math.Max(1f, size / 16f);
        var rect = new RectangleF(inset, inset, size - 2 * inset, size - 2 * inset);
        using (var g = Graphics.FromImage(page))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using var path = RoundedRect(rect, rect.Height / 5f);
            using var b = new SolidBrush(fg);
            g.FillPath(b, path);
        }
        using (var g = Graphics.FromImage(mask))
        {
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var text = day.ToString();
            // Size the digits once against "88" so every day renders the same size; condensed face where available.
            using var font = FitFont(g, "88", rect.Width * 0.86f, rect.Height * 0.78f);
            using var path = new GraphicsPath();
            path.AddString(text, font.FontFamily, (int)FontStyle.Bold, font.Size, PointF.Empty, StringFormat.GenericTypographic);
            var ink = path.GetBounds();
            using var m = new Matrix();
            m.Translate(rect.X + (rect.Width - ink.Width) / 2f - ink.X, rect.Y + (rect.Height - ink.Height) / 2f - ink.Y);
            path.Transform(m);
            g.FillPath(Brushes.White, path);
        }
        // Knock the digits out of the page: alpha *= (1 - maskAlpha).
        for (var y = 0; y < size; y++)
            for (var x = 0; x < size; x++)
            {
                var p = page.GetPixel(x, y);
                var a = mask.GetPixel(x, y).A;
                if (a == 0 || p.A == 0) continue;
                page.SetPixel(x, y, Color.FromArgb(p.A * (255 - a) / 255, p.R, p.G, p.B));
            }
        var h = page.GetHicon();
        var icon = (Icon)Icon.FromHandle(h).Clone();
        Native.DestroyIcon(h);
        return icon;
    }

    private static Font FitFont(Graphics g, string sample, float maxW, float maxH)
    {
        FontFamily family;
        try { family = new FontFamily("Bahnschrift SemiBold SemiConden"); }
        catch { family = new FontFamily("Segoe UI"); }
        var size = maxH;
        while (size > 4)
        {
            using var path = new GraphicsPath();
            path.AddString(sample, family, (int)FontStyle.Bold, size, PointF.Empty, StringFormat.GenericTypographic);
            var b = path.GetBounds();
            if (b.Width <= maxW && b.Height <= maxH) break;
            size -= 0.5f;
        }
        return new Font(family, size, FontStyle.Bold, GraphicsUnit.Pixel);
    }

    private static GraphicsPath RoundedRect(RectangleF r, float radius)
    {
        var d = radius * 2;
        var p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    private void ToggleCalendar()
    {
        // A click on the icon while the flyout is open first deactivates (closes) it; don't reopen immediately.
        if ((DateTime.Now - _flyoutClosedAt).TotalMilliseconds < 300) return;
        if (_flyout is { IsVisible: true }) { _flyout.Close(); return; }
        ShowCalendar();
    }

    public void ShowCalendar()
    {
        _flyout?.Close();
        _flyout = new CalendarFlyout(_host);
        _flyout.Closed += (_, _) => { _flyoutClosedAt = DateTime.Now; _flyout = null; };
        _flyout.ShowNearTray();
    }

    private ContextMenuStrip BuildMenu()
    {
        var s = _host.Settings.Current;
        var menu = new ContextMenuStrip { ShowImageMargin = false, Font = new Font("Segoe UI", 9f) };
        string Keys(KeyCombo? c) => c?.ToString() ?? "";

        menu.Items.Add(new ToolStripMenuItem("Calendar", null, (_, _) => ShowCalendar()));
        menu.Items.Add(new ToolStripSeparator());

        var clip = new ToolStripMenuItem("Clipboard && Snippets");
        clip.DropDownItems.Add(new ToolStripMenuItem("Show Clipboard && Snippets", null, (_, _) => _host.Popup.Show()) { ShortcutKeyDisplayString = Keys(s.Shortcuts.Popup) });
        clip.DropDownItems.Add(new ToolStripMenuItem("Snippets Manager…", null, (_, _) => _host.OpenSnippetsManager()));
        clip.DropDownItems.Add(new ToolStripSeparator());
        clip.DropDownItems.Add(new ToolStripMenuItem("Clear History…", null, (_, _) => ClearHistory()));
        menu.Items.Add(clip);

        var cap = new ToolStripMenuItem("Capture");
        cap.DropDownItems.Add(new ToolStripMenuItem("Capture Area", null, (_, _) => _host.Capture.CaptureArea()) { ShortcutKeyDisplayString = Keys(s.Shortcuts.Area) });
        cap.DropDownItems.Add(new ToolStripMenuItem("Capture Fullscreen", null, (_, _) => _host.Capture.CaptureFullscreen()) { ShortcutKeyDisplayString = Keys(s.Shortcuts.Fullscreen) });
        cap.DropDownItems.Add(new ToolStripMenuItem("Scrolling Capture", null, (_, _) => _host.Capture.CaptureScrolling()) { ShortcutKeyDisplayString = Keys(s.Shortcuts.Scrolling) });
        menu.Items.Add(cap);

        if (s.Translation.Enabled)
        {
            var tr = new ToolStripMenuItem("Translate");
            tr.DropDownItems.Add(new ToolStripMenuItem("Translate to English", null, (_, _) => _host.Translation.Request(TranslationLanguage.English)) { ShortcutKeyDisplayString = Keys(s.Shortcuts.TranslateEnglish) });
            tr.DropDownItems.Add(new ToolStripMenuItem("Translate to Hungarian", null, (_, _) => _host.Translation.Request(TranslationLanguage.Hungarian)) { ShortcutKeyDisplayString = Keys(s.Shortcuts.TranslateHungarian) });
            menu.Items.Add(tr);
        }

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Settings…", null, (_, _) => _host.OpenSettings()));
        menu.Items.Add(new ToolStripMenuItem("Quit Mukker", null, (_, _) => _host.Quit()));
        return menu;
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
        _midnight.Stop();
        _icon.Visible = false;
        _icon.Dispose();
        _current?.Dispose();
    }
}
