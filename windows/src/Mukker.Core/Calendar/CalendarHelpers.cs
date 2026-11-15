using System.Globalization;
using Mukker.Core.Settings;

namespace Mukker.Core.Calendar;

/// <summary>Month geometry: always 6 rows × 7 columns so the flyout never changes height while paging.</summary>
public static class MonthGrid
{
    public const int Rows = 6;
    public const int Columns = 7;

    /// <summary>Maps the macOS numbering (0 system, 1 Sunday, 2 Monday, 7 Saturday) to a DayOfWeek.</summary>
    public static DayOfWeek FirstDay(int setting, CultureInfo? culture = null) => setting switch
    {
        >= 1 and <= 7 => (DayOfWeek)(setting - 1),
        _ => (culture ?? CultureInfo.CurrentCulture).DateTimeFormat.FirstDayOfWeek,
    };

    /// <summary>The 42 dates shown for <paramref name="year"/>/<paramref name="month"/>, starting on <paramref name="firstDay"/>.</summary>
    public static DateOnly[] Days(int year, int month, DayOfWeek firstDay)
    {
        var first = new DateOnly(year, month, 1);
        var lead = ((int)first.DayOfWeek - (int)firstDay + 7) % 7;
        var start = first.AddDays(-lead);
        var days = new DateOnly[Rows * Columns];
        for (var i = 0; i < days.Length; i++) days[i] = start.AddDays(i);
        return days;
    }

    /// <summary>Weekday column headers, two letters, in display order.</summary>
    public static string[] WeekdaySymbols(DayOfWeek firstDay, CultureInfo? culture = null)
    {
        var names = (culture ?? CultureInfo.CurrentCulture).DateTimeFormat.ShortestDayNames;
        return Enumerable.Range(0, 7).Select(i => names[((int)firstDay + i) % 7]).ToArray();
    }

    /// <summary>Week number for a row: ISO-8601 when weeks start on Monday, otherwise the culture's rule.</summary>
    public static int WeekNumber(DateOnly rowStart, DayOfWeek firstDay, CultureInfo? culture = null)
    {
        var dt = rowStart.ToDateTime(TimeOnly.MinValue);
        if (firstDay == DayOfWeek.Monday) return ISOWeek.GetWeekOfYear(dt);
        var c = culture ?? CultureInfo.CurrentCulture;
        // Use the week's Thursday-equivalent (mid-week) so a row spanning a year boundary gets one number.
        return c.Calendar.GetWeekOfYear(dt.AddDays(3), c.DateTimeFormat.CalendarWeekRule, firstDay);
    }

    /// <summary>"Today", "Tomorrow", "Yesterday" or e.g. "Sun, Nov 15".</summary>
    public static string DayHeader(DateOnly day, DateOnly today, CultureInfo? culture = null)
    {
        var diff = day.DayNumber - today.DayNumber;
        return diff switch
        {
            0 => "Today",
            1 => "Tomorrow",
            -1 => "Yesterday",
            _ => day.ToString("ddd, MMM d", culture ?? CultureInfo.CurrentCulture),
        };
    }
}

public static class DateLabelFormatter
{
    /// <summary>The tray tooltip text for <paramref name="format"/>, like the Mac's menu-bar label presets.</summary>
    public static string Format(DateTime date, MenuBarFormat format, string customPattern, CultureInfo? culture = null)
    {
        var c = culture ?? CultureInfo.CurrentCulture;
        switch (format)
        {
            case MenuBarFormat.DayNumberOnly: return date.Day.ToString(c);
            case MenuBarFormat.Weekday: return date.ToString("ddd", c);
            case MenuBarFormat.MonthDay: return date.ToString("MMM d", c);
            case MenuBarFormat.WeekdayMonthDay: return date.ToString("ddd, MMM d", c);
            case MenuBarFormat.MonthDayWeekday: return date.ToString("MMM d., ddd", c);
            default:
                string s;
                try { s = string.IsNullOrWhiteSpace(customPattern) ? "" : date.ToString(customPattern, c); }
                catch (FormatException) { s = ""; }
                return string.IsNullOrWhiteSpace(s) ? date.ToString("MMM d", c) : s;
        }
    }
}

public static class ChimeSchedule
{
    /// <summary>The next fire time: the top of the coming hour, at second 1 (so an early fire can't read the previous hour).</summary>
    public static DateTime NextFire(DateTime now)
    {
        var top = new DateTime(now.Year, now.Month, now.Day, now.Hour, 0, 1, now.Kind);
        return top > now ? top : top.AddHours(1);
    }

    /// <summary>Whether <paramref name="hour"/> is within [start, end]; a range that ends before it starts wraps past midnight.</summary>
    public static bool IsActive(int hour, int start, int end) =>
        start <= end ? hour >= start && hour <= end : hour >= start || hour <= end;

    /// <summary>Delay until the next midnight (for the tray day number).</summary>
    public static TimeSpan UntilMidnight(DateTime now) => now.Date.AddDays(1) - now + TimeSpan.FromSeconds(1);
}
