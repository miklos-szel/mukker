using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Mukker.App.Clipboard;
using Mukker.App.Editor;
using Mukker.App.Interop;
using Mukker.Core.Capture;
using Mukker.Core.Settings;

namespace Mukker.App.Capture;

/// <summary>A capture, plus the display scale it was taken at (for "downscale to 100%").</summary>
internal sealed record CaptureResult(BitmapSource Image, double Scale);

/// <summary>
/// Hotkey/menu → grab the screen → (select) → route by "after capture": open the editor, copy, or save.
/// Captures are stateless: they live only until copied or saved.
/// </summary>
internal sealed class CaptureCoordinator
{
    private readonly AppHost _host;
    private bool _busy;

    public CaptureCoordinator(AppHost host) => _host = host;

    private CaptureSettings Settings => _host.Settings.Current.Capture;

    public async void CaptureArea()
    {
        if (_busy) return;
        _busy = true;
        try
        {
            var vs = ScreenGrabber.VirtualScreen();
            var frozen = ScreenGrabber.Capture(vs);
            var rect = await SelectionSession.Select(frozen, Settings.ShowMagnifierDuringCapture);
            if (rect is not { } r) return;
            var crop = frozen.Crop(new Int32Rect(r.X - vs.X, r.Y - vs.Y, r.Width, r.Height));
            Handle(new CaptureResult(crop.ToBitmap(), ScaleAt(r)));
        }
        catch (Exception e) { AppHost.Log($"capture area failed: {e.Message}"); }
        finally { _busy = false; }
    }

    public void CaptureFullscreen()
    {
        if (_busy) return;
        try
        {
            var m = ScreenGrabber.MonitorUnderCursor();
            Handle(new CaptureResult(ScreenGrabber.Capture(m.Bounds).ToBitmap(), m.Scale));
        }
        catch (Exception e) { AppHost.Log($"capture fullscreen failed: {e.Message}"); }
    }

    public async void CaptureScrolling()
    {
        if (_busy) return;
        _busy = true;
        try
        {
            var vs = ScreenGrabber.VirtualScreen();
            var frozen = ScreenGrabber.Capture(vs);
            var rect = await SelectionSession.Select(frozen, loupe: false, minSize: 9);
            if (rect is not { } r) return;
            // Let the overlays disappear before grabbing live frames.
            await Task.Delay(150);
            var image = await ScrollingCapture.Run(r, Settings.ScrollMaxHeight, Settings.ScrollSpeed);
            if (image != null) Handle(new CaptureResult(image, ScaleAt(r)));
        }
        catch (Exception e) { AppHost.Log($"scrolling capture failed: {e.Message}"); }
        finally { _busy = false; }
    }

    private static double ScaleAt(Int32Rect r)
    {
        foreach (var m in ScreenGrabber.Monitors())
            if (r.X >= m.Bounds.X && r.X < m.Bounds.X + m.Bounds.Width && r.Y >= m.Bounds.Y && r.Y < m.Bounds.Y + m.Bounds.Height)
                return m.Scale;
        return 1;
    }

    private void Handle(CaptureResult capture)
    {
        switch (Settings.AfterCapture)
        {
            case AfterCapture.Copy:
                ImageOutput.Copy(ImageOutput.Prepare(capture.Image, capture.Scale, Settings));
                break;
            case AfterCapture.Save:
                var saved = ImageOutput.Save(ImageOutput.Prepare(capture.Image, capture.Scale, Settings), Settings);
                if (saved.Error != null)
                {
                    // Don't drop the failure: open the capture so nothing is lost, and say why.
                    var w = EditorWindow.Open(_host, capture);
                    MessageBox.Show(w, $"The capture could not be saved: {saved.Error}", "Mukker", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
                break;
            default:
                EditorWindow.Open(_host, capture);
                break;
        }
    }
}

internal static class ImageOutput
{
    /// <summary>Applies the optional "downscale to 100% scale".</summary>
    public static BitmapSource Prepare(BitmapSource image, double scale, CaptureSettings s)
    {
        if (!s.DownscaleToStandard || scale <= 1.01) return image;
        var t = new TransformedBitmap(image, new ScaleTransform(1 / scale, 1 / scale));
        t.Freeze();
        return t;
    }

    public static byte[] Encode(BitmapSource image, SaveFormat format)
    {
        BitmapEncoder enc = format == SaveFormat.Jpeg ? new JpegBitmapEncoder { QualityLevel = 90 } : new PngBitmapEncoder();
        BitmapSource src = image;
        if (format == SaveFormat.Jpeg)
        {
            // JPEG has no alpha: flatten onto white.
            var fmt = new FormatConvertedBitmap(image, PixelFormats.Bgr32, null, 0);
            src = fmt;
        }
        enc.Frames.Add(BitmapFrame.Create(src));
        using var ms = new MemoryStream();
        enc.Save(ms);
        return ms.ToArray();
    }

    /// <summary>PNG + DIB on the clipboard. The monitor records it like any copy, so captures land in history.</summary>
    public static bool Copy(BitmapSource image)
    {
        var data = new DataObject();
        data.SetImage(image);
        data.SetData("PNG", new MemoryStream(Encode(image, SaveFormat.Png)));
        return Paster.SetClipboard(data);
    }

    /// <summary>Saves silently into the configured folder; never overwrites (" 2", " 3", … on collisions).</summary>
    public static (string? Path, string? Error) Save(BitmapSource image, CaptureSettings s)
    {
        try
        {
            var dir = string.IsNullOrWhiteSpace(s.SaveDirectory) ? Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory) : s.SaveDirectory!;
            Directory.CreateDirectory(dir);
            var ext = s.SaveFormat == SaveFormat.Jpeg ? "jpg" : "png";
            var path = ExportNaming.UniquePath(dir, DateTime.Now, ext);
            using var fs = new FileStream(path, FileMode.CreateNew, FileAccess.Write);
            var bytes = Encode(image, s.SaveFormat);
            fs.Write(bytes, 0, bytes.Length);
            return (path, null);
        }
        catch (Exception e) { return (null, e.Message); }
    }
}

/// <summary>
/// Scrolls the region with synthetic wheel input, grabs a frame after each step, finds the overlap by
/// row signatures and appends only the new strip. Stops after two steps without movement, at the max
/// height, after 400 steps, or on Esc. Sticky headers can show up as repeated bands.
/// <para>
/// Two things keep the stitch exact with Windows 11's smooth scrolling. Every frame is taken only once the
/// region has stopped changing (<see cref="GrabSettled"/>): a frame grabbed mid-animation or mid-redraw is
/// torn, and its seam shows. And movement is always measured against the <em>last stitched</em> frame —
/// after an overshoot is stepped back, the view rarely lands exactly where it was, so re-baselining on it
/// would offset everything after it (whole lines went missing that way).
/// </para>
/// </summary>
internal static class ScrollingCapture
{
    /// <summary>Longest wait for the region to settle after a scroll step before the frame is used anyway.</summary>
    private static readonly TimeSpan SettleTimeout = TimeSpan.FromMilliseconds(900);
    private static readonly TimeSpan SettlePoll = TimeSpan.FromMilliseconds(35);

    public static async Task<BitmapSource?> Run(Int32Rect region, int maxHeight, double speed)
    {
        Native.GetCursorPos(out var savedCursor);
        Native.SetCursorPos(region.X + region.Width / 2, region.Y + region.Height / 2);
        var delay = TimeSpan.FromSeconds(Math.Max(0.05, 0.30 - 0.22 * Math.Clamp(speed, 0, 1)));
        try
        {
            var (first, firstSig) = await GrabSettled(region);
            var rows = new List<byte[]>();
            AppendRows(rows, first, 0);
            // The signature of the frame whose bottom is the bottom of `rows`.
            var stitchedSig = firstSig;
            var notches = 2;
            var stalls = 0;
            for (var i = 0; i < 400 && rows.Count < maxHeight; i++)
            {
                if (EscPressed()) break;
                Native.SendWheel(-notches);
                await Task.Delay(delay);
                var (frame, sig) = await GrabSettled(region);
                var advance = Core.Capture.ImageStitcher.FindAdvance(stitchedSig, sig);
                if (advance is null)
                {
                    // Scrolled past the overlap: step back, then stitch whatever that landed on against the
                    // last stitched frame — never re-baseline on it blindly.
                    Native.SendWheel(notches);
                    await Task.Delay(delay);
                    notches = Math.Max(1, notches / 2);
                    var (back, backSig) = await GrabSettled(region);
                    var backAdvance = Core.Capture.ImageStitcher.FindAdvance(stitchedSig, backSig);
                    if (backAdvance is null)
                    {
                        // Lost track of where we are; stop with a correct image rather than a wrong one.
                        AppHost.Log("scrolling capture: lost the overlap after stepping back, stopping");
                        break;
                    }
                    if (backAdvance > 1)
                    {
                        AppendRows(rows, back, back.Height - backAdvance.Value);
                        stitchedSig = backSig;
                    }
                    if (notches == 1 && i > 3) { stalls++; if (stalls >= 3) break; }
                    continue;
                }
                if (advance <= 1)
                {
                    if (++stalls >= 2) break;
                    continue;
                }
                stalls = 0;
                AppendRows(rows, frame, frame.Height - advance.Value);
                stitchedSig = sig;
                // Aim for steps of ~60% of the region so the next frame still overlaps.
                var perNotch = (double)advance.Value / notches;
                notches = Math.Clamp((int)(region.Height * 0.6 / Math.Max(1, perNotch)), 1, 20);
            }
            var height = Math.Min(rows.Count, maxHeight);
            var stride = region.Width * 4;
            var pixels = new byte[stride * height];
            for (var y = 0; y < height; y++) Buffer.BlockCopy(rows[y], 0, pixels, y * stride, stride);
            var bmp = BitmapSource.Create(region.Width, height, 96, 96, PixelFormats.Bgra32, null, pixels, stride);
            bmp.Freeze();
            return bmp;
        }
        finally
        {
            Native.SetCursorPos(savedCursor.X, savedCursor.Y);
        }
    }

    private static bool EscPressed() => (Native.GetAsyncKeyState(0x1B) & 0x8000) != 0;

    /// <summary>
    /// Grabs the region until two consecutive grabs are identical (or <see cref="SettleTimeout"/> passes), so
    /// a smooth-scroll animation or a half-finished redraw never ends up in the stitch.
    /// </summary>
    private static async Task<(Grab Frame, byte[][] Sig)> GrabSettled(Int32Rect region)
    {
        var frame = ScreenGrabber.Capture(region);
        var sig = Signatures(frame);
        var deadline = DateTime.UtcNow + SettleTimeout;
        while (DateTime.UtcNow < deadline)
        {
            await Task.Delay(SettlePoll);
            var next = ScreenGrabber.Capture(region);
            var nextSig = Signatures(next);
            var settled = Core.Capture.ImageStitcher.FindAdvance(sig, nextSig) == 0;
            frame = next;
            sig = nextSig;
            if (settled) break;
        }
        return (frame, sig);
    }

    private static byte[][] Signatures(Grab g) =>
        Core.Capture.ImageStitcher.RowSignatures(g.Pixels, g.Width, g.Height, g.Stride);

    private static void AppendRows(List<byte[]> rows, Grab g, int fromRow)
    {
        for (var y = Math.Max(0, fromRow); y < g.Height; y++)
        {
            var row = new byte[g.Stride];
            Buffer.BlockCopy(g.Pixels, y * g.Stride, row, 0, g.Stride);
            rows.Add(row);
        }
    }
}
