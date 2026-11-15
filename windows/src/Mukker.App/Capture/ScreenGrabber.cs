using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Mukker.App.Interop;

namespace Mukker.App.Capture;

/// <summary>A monitor in physical pixels (the process is per-monitor DPI aware).</summary>
internal sealed record MonitorInfo(Int32Rect Bounds, double Scale);

/// <summary>A captured BGRA bitmap plus where it came from, and the display scale it was taken at.</summary>
internal sealed class Grab
{
    public required byte[] Pixels { get; init; }
    public required int Width { get; init; }
    public required int Height { get; init; }
    public required Int32Rect Bounds { get; init; } // virtual-screen pixels
    public int Stride => Width * 4;

    public BitmapSource ToBitmap()
    {
        var bmp = BitmapSource.Create(Width, Height, 96, 96, PixelFormats.Bgra32, null, Pixels, Stride);
        bmp.Freeze();
        return bmp;
    }

    /// <summary>A sub-rectangle (in this grab's local pixels).</summary>
    public Grab Crop(Int32Rect local)
    {
        var x = Math.Clamp(local.X, 0, Width);
        var y = Math.Clamp(local.Y, 0, Height);
        var w = Math.Clamp(local.Width, 0, Width - x);
        var h = Math.Clamp(local.Height, 0, Height - y);
        var pixels = new byte[w * h * 4];
        for (var row = 0; row < h; row++)
            Buffer.BlockCopy(Pixels, (y + row) * Stride + x * 4, pixels, row * w * 4, w * 4);
        return new Grab { Pixels = pixels, Width = w, Height = h, Bounds = new Int32Rect(Bounds.X + x, Bounds.Y + y, w, h) };
    }
}

internal static class ScreenGrabber
{
    public static List<MonitorInfo> Monitors()
    {
        var list = new List<MonitorInfo>();
        Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr dc, ref Native.RECT r, IntPtr data) =>
        {
            double scale = 1;
            try { if (Native.GetDpiForMonitor(h, 0, out var dx, out _) == 0) scale = dx / 96.0; } catch { }
            list.Add(new MonitorInfo(new Int32Rect(r.Left, r.Top, r.Width, r.Height), scale));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static MonitorInfo MonitorUnderCursor()
    {
        Native.GetCursorPos(out var p);
        var all = Monitors();
        foreach (var m in all)
            if (p.X >= m.Bounds.X && p.X < m.Bounds.X + m.Bounds.Width && p.Y >= m.Bounds.Y && p.Y < m.Bounds.Y + m.Bounds.Height)
                return m;
        return all.Count > 0 ? all[0] : new MonitorInfo(new Int32Rect(0, 0, 1920, 1080), 1);
    }

    public static Int32Rect VirtualScreen() => new(
        Native.GetSystemMetrics(Native.SM_XVIRTUALSCREEN), Native.GetSystemMetrics(Native.SM_YVIRTUALSCREEN),
        Native.GetSystemMetrics(Native.SM_CXVIRTUALSCREEN), Native.GetSystemMetrics(Native.SM_CYVIRTUALSCREEN));

    /// <summary>BitBlt of a virtual-screen rectangle into a top-down 32bpp buffer. The cursor is not captured.</summary>
    public static Grab Capture(Int32Rect r)
    {
        var screen = Native.GetDC(IntPtr.Zero);
        var mem = Native.CreateCompatibleDC(screen);
        var bmi = new Native.BITMAPINFOHEADER
        {
            biSize = (uint)Marshal.SizeOf<Native.BITMAPINFOHEADER>(),
            biWidth = r.Width,
            biHeight = -r.Height, // top-down
            biPlanes = 1,
            biBitCount = 32,
        };
        var dib = Native.CreateDIBSection(screen, ref bmi, 0, out var bits, IntPtr.Zero, 0);
        var old = Native.SelectObject(mem, dib);
        try
        {
            Native.BitBlt(mem, 0, 0, r.Width, r.Height, screen, r.X, r.Y, Native.SRCCOPY | Native.CAPTUREBLT);
            var pixels = new byte[r.Width * r.Height * 4];
            Marshal.Copy(bits, pixels, 0, pixels.Length);
            // BitBlt leaves alpha undefined (often 0): force opaque.
            for (var i = 3; i < pixels.Length; i += 4) pixels[i] = 255;
            return new Grab { Pixels = pixels, Width = r.Width, Height = r.Height, Bounds = r };
        }
        finally
        {
            Native.SelectObject(mem, old);
            Native.DeleteObject(dib);
            Native.DeleteDC(mem);
            Native.ReleaseDC(IntPtr.Zero, screen);
        }
    }
}
