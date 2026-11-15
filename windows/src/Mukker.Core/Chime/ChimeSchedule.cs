using System;

namespace Mukker.Core.Chime;

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
}
