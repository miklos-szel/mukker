using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Media;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Mukker.App.Interop;
using Mukker.Core.Calendar;
using Mukker.Core.Settings;

namespace Mukker.App.Calendar;

/// <summary>
/// The month calendar that opens from the tray icon: a pageable 6×7 grid (always six rows so it never
/// changes height), today filled with the accent, the selected day ringed. Display only — no events.
/// </summary>
internal sealed class CalendarFlyout : Window
{
    private const double CellW = 36, CellH = 32;
    private readonly AppHost _host;
    private DateOnly _anchor;     // first of the displayed month
    private DateOnly _selected;
    private readonly TextBlock _title = new() { FontSize = 15, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    private readonly Grid _grid = new();
    private readonly TextBlock _dayHeader = new() { FontSize = 14, FontWeight = FontWeights.SemiBold };
    private readonly TextBlock _dayDetail = new() { FontSize = 12 };

    public CalendarFlyout(AppHost host)
    {
        _host = host;
        var today = DateOnly.FromDateTime(DateTime.Now);
        _selected = today;
        _anchor = new DateOnly(today.Year, today.Month, 1);

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        SizeToContent = SizeToContent.WidthAndHeight;
        Background = (Brush)FindResource("Surface");
        Title = "Mukker Calendar";

        var root = new StackPanel { Margin = new Thickness(14, 12, 14, 14) };

        var header = new DockPanel { Margin = new Thickness(2, 0, 0, 8) };
        var nav = new StackPanel { Orientation = Orientation.Horizontal };
        nav.Children.Add(NavButton("\uE76B", "Previous month", () => Page(-1)));
        nav.Children.Add(NavButton("\uE91F", "Today", GoToday, small: true));
        nav.Children.Add(NavButton("\uE76C", "Next month", () => Page(1)));
        DockPanel.SetDock(nav, Dock.Right);
        header.Children.Add(nav);
        header.Children.Add(_title);
        root.Children.Add(header);

        root.Children.Add(_grid);

        root.Children.Add(new Border { Height = 1, Background = (Brush)FindResource("Hairline"), Margin = new Thickness(0, 10, 0, 8) });
        _dayDetail.Foreground = (Brush)FindResource("InkSoft");
        root.Children.Add(_dayHeader);
        root.Children.Add(_dayDetail);

        Content = new Border
        {
            Child = root,
            BorderBrush = (Brush)FindResource("Hairline"),
            BorderThickness = new Thickness(1),
        };

        Deactivated += (_, _) => Close();
        PreviewKeyDown += OnKey;
        SourceInitialized += (_, _) => Native.RoundCorners(new WindowInteropHelper(this).Handle);
        Rebuild();
    }

    private Button NavButton(string glyph, string tip, Action act, bool small = false)
    {
        var b = new Button
        {
            Content = glyph,
            ToolTip = tip,
            Style = (Style)FindResource("IconButton"),
            FontSize = small ? 9 : 12,
        };
        b.Click += (_, _) => act();
        return b;
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Escape: Close(); break;
            case Key.Left: Select(_selected.AddDays(-1)); break;
            case Key.Right: Select(_selected.AddDays(1)); break;
            case Key.Up: Select(_selected.AddDays(-7)); break;
            case Key.Down: Select(_selected.AddDays(7)); break;
            case Key.PageUp: Page(-1); break;
            case Key.PageDown: Page(1); break;
            case Key.Home: GoToday(); break;
            default: return;
        }
        e.Handled = true;
    }

    private void Page(int months)
    {
        _anchor = _anchor.AddMonths(months);
        Rebuild();
    }

    private void GoToday()
    {
        var today = DateOnly.FromDateTime(DateTime.Now);
        _selected = today;
        _anchor = new DateOnly(today.Year, today.Month, 1);
        Rebuild();
    }

    private void Select(DateOnly day)
    {
        _selected = day;
        if (day.Year != _anchor.Year || day.Month != _anchor.Month) _anchor = new DateOnly(day.Year, day.Month, 1);
        Rebuild();
    }

    private void Rebuild()
    {
        var settings = _host.Settings.Current.Calendar;
        var culture = CultureInfo.CurrentCulture;
        var firstDay = MonthGrid.FirstDay(settings.FirstWeekday, culture);
        var weekCol = settings.ShowsWeekNumbers ? 1 : 0;
        var today = DateOnly.FromDateTime(DateTime.Now);
        var accent = (Brush)FindResource("Accent");
        var ink = (Brush)FindResource("Ink");
        var soft = (Brush)FindResource("InkSoft");

        _title.Text = _anchor.ToString("MMMM yyyy", culture);
        _grid.Children.Clear();
        _grid.RowDefinitions.Clear();
        _grid.ColumnDefinitions.Clear();
        for (var c = 0; c < 7 + weekCol; c++)
            _grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(c == 0 && weekCol == 1 ? 28 : CellW) });
        _grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(22) });
        for (var r = 0; r < MonthGrid.Rows; r++) _grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(CellH) });

        var symbols = MonthGrid.WeekdaySymbols(firstDay, culture);
        for (var c = 0; c < 7; c++)
            Place(new TextBlock { Text = symbols[c], Foreground = soft, FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }, 0, c + weekCol);

        var days = MonthGrid.Days(_anchor.Year, _anchor.Month, firstDay);
        for (var i = 0; i < days.Length; i++)
        {
            var day = days[i];
            int row = i / 7 + 1, col = i % 7;
            if (weekCol == 1 && col == 0)
                Place(new TextBlock
                {
                    Text = MonthGrid.WeekNumber(day, firstDay, culture).ToString(culture),
                    Foreground = soft, FontSize = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                }, row, 0);

            var inMonth = day.Month == _anchor.Month;
            var isToday = day == today;
            var isSelected = day == _selected;
            var cell = new Grid { Cursor = Cursors.Hand, Background = Brushes.Transparent };
            if (isToday)
                cell.Children.Add(new Ellipse { Width = 28, Height = 28, Fill = accent });
            else if (isSelected)
                cell.Children.Add(new Ellipse { Width = 28, Height = 28, Stroke = accent, StrokeThickness = 1.6 });
            cell.Children.Add(new TextBlock
            {
                Text = day.Day.ToString(culture),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                FontWeight = isToday ? FontWeights.Bold : FontWeights.Normal,
                Foreground = isToday ? Brushes.White : inMonth ? ink : soft,
                Opacity = inMonth || isToday ? 1 : 0.55,
            });
            if (isSelected && isToday)
                cell.Children.Insert(0, new Ellipse { Width = 32, Height = 32, Stroke = accent, StrokeThickness = 1.2, Opacity = 0.6 });
            var captured = day;
            cell.MouseLeftButtonUp += (_, _) => Select(captured);
            Place(cell, row, col + weekCol);
        }

        _dayHeader.Text = MonthGrid.DayHeader(_selected, today, culture);
        var dt = _selected.ToDateTime(TimeOnly.MinValue);
        var week = MonthGrid.WeekNumber(_selected.AddDays(-(((int)_selected.DayOfWeek - (int)firstDay + 7) % 7)), firstDay, culture);
        _dayDetail.Text = $"{dt.ToString("D", culture)} · Week {week} · Day {dt.DayOfYear}";
    }

    private void Place(UIElement e, int row, int col)
    {
        Grid.SetRow(e, row);
        Grid.SetColumn(e, col);
        _grid.Children.Add(e);
    }

    /// <summary>Opens above the taskbar near the cursor (the tray icon), clamped to the work area.</summary>
    public void ShowNearTray()
    {
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = -10000;
        Top = -10000;
        Show();
        UpdateLayout();
        var cursor = System.Windows.Forms.Cursor.Position;
        var screen = System.Windows.Forms.Screen.FromPoint(cursor);
        var source = PresentationSource.FromVisual(this);
        var m = source?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var work = screen.WorkingArea;
        var topLeft = m.Transform(new Point(work.Left, work.Top));
        var bottomRight = m.Transform(new Point(work.Right, work.Bottom));
        var cur = m.Transform(new Point(cursor.X, cursor.Y));
        const double margin = 12;
        var left = Math.Min(Math.Max(cur.X - ActualWidth / 2, topLeft.X + margin), bottomRight.X - ActualWidth - margin);
        // Taskbar at the bottom (the usual case) → above it; at the top → below it.
        var top = cur.Y > (topLeft.Y + bottomRight.Y) / 2 ? bottomRight.Y - ActualHeight - margin : topLeft.Y + margin;
        Left = left;
        Top = top;
        Activate();
        Focus();
    }
}

/// <summary>
/// Plays a sound at the top of every hour within the active range. Re-armed on an absolute deadline after
/// every fire, clock change and resume — never a repeating one-hour timer, which drifts with sleep.
/// </summary>
internal sealed class ChimeService
{
    public const string MediaFolder = @"C:\Windows\Media";
    private readonly Func<CalendarSettings> _settings;
    private readonly DispatcherTimer _timer = new();
    private SoundPlayer? _player; // retained: playback is async

    public ChimeService(Func<CalendarSettings> settings)
    {
        _settings = settings;
        _timer.Tick += (_, _) =>
        {
            _timer.Stop();
            var s = _settings();
            if (s.HourlyChime && ChimeSchedule.IsActive(DateTime.Now.Hour, s.HourlyChimeStartHour, s.HourlyChimeEndHour)) Play();
            Reschedule();
        };
    }

    public void Reschedule()
    {
        _timer.Stop();
        if (!_settings().HourlyChime) return;
        var debugEveryMinute = Environment.GetEnvironmentVariable("MUKKER_CHIME_EVERY_MINUTE") == "1";
        var now = DateTime.Now;
        var next = debugEveryMinute
            ? new DateTime(now.Year, now.Month, now.Day, now.Hour, now.Minute, 1).AddMinutes(now.Second >= 1 ? 1 : 0)
            : ChimeSchedule.NextFire(now);
        _timer.Interval = next - now;
        _timer.Start();
    }

    public static string[] AvailableSounds()
    {
        try
        {
            return Directory.GetFiles(MediaFolder, "*.wav").Select(System.IO.Path.GetFileNameWithoutExtension).OfType<string>()
                .OrderBy(n => n, StringComparer.CurrentCultureIgnoreCase).ToArray();
        }
        catch { return Array.Empty<string>(); }
    }

    public void Play(string? name = null)
    {
        name ??= _settings().HourlyChimeSound;
        var path = System.IO.Path.Combine(MediaFolder, name + ".wav");
        if (!File.Exists(path)) path = System.IO.Path.Combine(MediaFolder, "Windows Notify System Generic.wav");
        if (!File.Exists(path)) { SystemSounds.Asterisk.Play(); return; }
        try
        {
            _player?.Dispose();
            _player = new SoundPlayer(path);
            _player.Play();
        }
        catch { SystemSounds.Asterisk.Play(); }
    }
}
