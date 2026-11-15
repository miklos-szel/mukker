using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Mukker.App.Interop;
using Mukker.Core;
using Mukker.Core.Clipboard;
using Mukker.Core.Settings;
using Mukker.Core.Storage;

namespace Mukker.App.Clipboard;

/// <summary>Raw clipboard contents read in one OpenClipboard session.</summary>
internal sealed class RawClipboard
{
    public HashSet<string> Formats { get; } = new();
    public List<string>? Files;
    public byte[]? Png;
    public byte[]? Dib;
    public string? Text;
    public byte[]? Rtf;
    public byte[]? Html;
    public string? ChromiumSourceUrl;
    public int? CanIncludeInHistory;
    public string? SourceProcess;
}

internal static class ClipboardReader
{
    private static readonly uint CfPng = Native.RegisterClipboardFormat("PNG");
    private static readonly uint CfRtf = Native.RegisterClipboardFormat("Rich Text Format");
    private static readonly uint CfHtml = Native.RegisterClipboardFormat("HTML Format");
    private static readonly uint CfChromiumUrl = Native.RegisterClipboardFormat("Chromium internal source URL");
    private static readonly uint CfCanInclude = Native.RegisterClipboardFormat("CanIncludeInClipboardHistory");

    public static bool TryOpen(IntPtr hwnd)
    {
        for (var i = 0; i < 10; i++)
        {
            if (Native.OpenClipboard(hwnd)) return true;
            Thread.Sleep(15);
        }
        return false;
    }

    /// <summary>Reads everything Mukker may need. Returns null if the clipboard could not be opened.</summary>
    public static RawClipboard? Read(IntPtr hwnd, int? maxTextChars)
    {
        var owner = Native.GetClipboardOwner();
        var source = Native.ProcessNameOfWindow(owner) ?? Native.ProcessNameOfWindow(Native.GetForegroundWindow());
        if (!TryOpen(hwnd)) return null;
        var raw = new RawClipboard { SourceProcess = source };
        try
        {
            uint f = 0;
            var name = new StringBuilder(256);
            while ((f = Native.EnumClipboardFormats(f)) != 0)
            {
                name.Clear();
                if (Native.GetClipboardFormatName(f, name, name.Capacity) > 0) raw.Formats.Add(name.ToString());
                else raw.Formats.Add("#" + f);
            }

            if (Native.IsClipboardFormatAvailable(CfCanInclude) && ReadBytes(CfCanInclude) is { Length: >= 4 } ci)
                raw.CanIncludeInHistory = BitConverter.ToInt32(ci, 0);
            if (Native.IsClipboardFormatAvailable(CfChromiumUrl) && ReadBytes(CfChromiumUrl) is { } url)
                raw.ChromiumSourceUrl = DecodeMaybeUnicode(url);

            if (Native.IsClipboardFormatAvailable(Native.CF_HDROP))
            {
                raw.Files = ReadFiles();
                return raw; // a file copy stops here: Explorer also offers names/icons that must not land as text/image
            }
            if (Native.IsClipboardFormatAvailable(CfPng)) raw.Png = ReadBytes(CfPng);
            else if (Native.IsClipboardFormatAvailable(Native.CF_DIB)) raw.Dib = ReadBytes(Native.CF_DIB);
            if (raw.Png != null || raw.Dib != null)
            {
                // Some apps (Office) put text alongside the picture; image wins, like on the Mac.
                return raw;
            }
            if (Native.IsClipboardFormatAvailable(Native.CF_UNICODETEXT) && ReadBytes(Native.CF_UNICODETEXT) is { } t)
            {
                var text = Encoding.Unicode.GetString(t);
                var nul = text.IndexOf('\0');
                raw.Text = nul >= 0 ? text[..nul] : text;
                if (maxTextChars is int lim && raw.Text.Length > lim) return raw; // too big: no need for rich text
                if (Native.IsClipboardFormatAvailable(CfRtf)) raw.Rtf = ReadBytes(CfRtf);
                else if (Native.IsClipboardFormatAvailable(CfHtml)) raw.Html = ReadBytes(CfHtml);
            }
            return raw;
        }
        finally
        {
            Native.CloseClipboard();
        }
    }

    private static string DecodeMaybeUnicode(byte[] b)
    {
        // Chromium writes this format as UTF-16; fall back to UTF-8 if it doesn't look like it.
        var s = b.Length >= 2 && b[1] == 0 ? Encoding.Unicode.GetString(b) : Encoding.UTF8.GetString(b);
        return s.TrimEnd('\0');
    }

    private static byte[]? ReadBytes(uint format)
    {
        var h = Native.GetClipboardData(format);
        if (h == IntPtr.Zero) return null;
        var p = Native.GlobalLock(h);
        if (p == IntPtr.Zero) return null;
        try
        {
            var size = (int)Native.GlobalSize(h).ToUInt64();
            var bytes = new byte[size];
            Marshal.Copy(p, bytes, 0, size);
            return bytes;
        }
        finally { Native.GlobalUnlock(h); }
    }

    private static List<string> ReadFiles()
    {
        var list = new List<string>();
        var h = Native.GetClipboardData(Native.CF_HDROP);
        if (h == IntPtr.Zero) return list;
        var count = Native.DragQueryFile(h, 0xFFFFFFFF, null, 0);
        for (uint i = 0; i < count; i++)
        {
            var len = Native.DragQueryFile(h, i, null, 0);
            var sb = new StringBuilder((int)len + 1);
            Native.DragQueryFile(h, i, sb, len + 1);
            list.Add(sb.ToString());
        }
        return list;
    }

    /// <summary>Wraps a packed DIB in a BMP file header so WPF can decode it.</summary>
    public static byte[] DibToBmp(byte[] dib)
    {
        var headerSize = BitConverter.ToInt32(dib, 0);
        var bitCount = BitConverter.ToUInt16(dib, 14);
        var compression = BitConverter.ToUInt32(dib, 16);
        var clrUsed = BitConverter.ToUInt32(dib, 32);
        var masks = compression == 3 && headerSize == 40 ? 12 : 0;
        var colors = clrUsed != 0 ? (int)clrUsed : bitCount <= 8 ? 1 << bitCount : 0;
        var offset = 14 + headerSize + masks + colors * 4;
        using var ms = new MemoryStream();
        using var w = new BinaryWriter(ms);
        w.Write((byte)'B');
        w.Write((byte)'M');
        w.Write(14 + dib.Length);
        w.Write(0);
        w.Write(offset);
        w.Write(dib);
        return ms.ToArray();
    }

    /// <summary>Canonical PNG bytes for the clipboard image (hash = dedupe key).</summary>
    public static (byte[] Png, int Width, int Height)? ToCanonicalPng(byte[]? png, byte[]? dib)
    {
        try
        {
            BitmapSource frame;
            if (png != null)
            {
                var dec = new PngBitmapDecoder(new MemoryStream(png), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                frame = dec.Frames[0];
            }
            else if (dib != null)
            {
                var dec = new BmpBitmapDecoder(new MemoryStream(DibToBmp(dib)), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                frame = dec.Frames[0];
            }
            else return null;
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(frame));
            using var ms = new MemoryStream();
            enc.Save(ms);
            return (ms.ToArray(), frame.PixelWidth, frame.PixelHeight);
        }
        catch (Exception e)
        {
            Debug.WriteLine($"clipboard image decode failed: {e.Message}");
            return null;
        }
    }
}

/// <summary>
/// Records clipboard changes into history. Reads on the UI thread (the clipboard is owned by a window),
/// then hashes, encodes and stores on one serial background queue so copy order is kept.
/// </summary>
internal sealed class ClipboardMonitor
{
    private readonly MessageWindow _window;
    private readonly ClipboardRepository _repo;
    private readonly RetentionService _retention;
    private readonly AppPaths _paths;
    private readonly Func<ClipboardSettings> _settings;
    private readonly SemaphoreSlim _queue = new(1, 1);
    private uint _suppressedSequence;

    /// <summary>The last clipboard sequence number fully processed (recorded or skipped).</summary>
    public uint ProcessedSequence { get; private set; }

    public ClipboardMonitor(MessageWindow window, ClipboardRepository repo, RetentionService retention, AppPaths paths, Func<ClipboardSettings> settings)
    {
        _window = window;
        _repo = repo;
        _retention = retention;
        _paths = paths;
        _settings = settings;
        _window.ClipboardUpdated += OnClipboardUpdated;
    }

    public void Start() => Native.AddClipboardFormatListener(_window.Handle);
    public void Stop() => Native.RemoveClipboardFormatListener(_window.Handle);

    /// <summary>Call right after our own clipboard write so it isn't re-captured as a fresh copy.</summary>
    public void SuppressCurrent() => _suppressedSequence = Native.GetClipboardSequenceNumber();

    private void OnClipboardUpdated()
    {
        var seq = Native.GetClipboardSequenceNumber();
        if (seq == _suppressedSequence) { ProcessedSequence = seq; return; }
        var settings = _settings();
        // Read slightly later: some apps announce the change before they finish writing all formats.
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background, () => ReadAndQueue(seq, settings));
    }

    private void ReadAndQueue(uint seq, ClipboardSettings settings)
    {
        var raw = ClipboardReader.Read(_window.Handle, settings.CharacterLimit);
        if (raw == null) { ProcessedSequence = seq; return; }
        var snap = new ClipboardSnapshot
        {
            Formats = raw.Formats,
            SourceProcess = raw.SourceProcess,
            ChromiumSourceUrl = raw.ChromiumSourceUrl,
            CanIncludeInHistory = raw.CanIncludeInHistory,
        };
        if (!CapturePolicy.ShouldRecord(snap, settings)) { ProcessedSequence = seq; return; }
        var createdAt = DateTime.Now;
        _ = Task.Run(async () =>
        {
            await _queue.WaitAsync();
            try { Persist(raw, settings, createdAt); }
            catch (Exception e) { Debug.WriteLine($"clipboard persist failed: {e}"); }
            finally
            {
                ProcessedSequence = seq;
                _queue.Release();
            }
        });
    }

    private void Persist(RawClipboard raw, ClipboardSettings s, DateTime createdAt)
    {
        ClipItem? item = null;
        Action<ClipItem>? writeSidecar = null;

        if (raw.Files != null)
        {
            if (!s.KeepFiles || raw.Files.Count == 0) return;
            var joined = string.Join("\n", raw.Files);
            item = new ClipItem
            {
                Kind = ClipKind.File, TextContent = joined, PreviewText = ClipText.FilesPreview(raw.Files),
                ContentHash = ClipText.Sha256(joined), SourceApp = raw.SourceProcess, CreatedAt = createdAt,
            };
        }
        else if (raw.Png != null || raw.Dib != null)
        {
            if (!s.KeepImages) return;
            if (ClipboardReader.ToCanonicalPng(raw.Png, raw.Dib) is not { } img) return;
            var hash = ClipText.Sha256(img.Png);
            item = new ClipItem
            {
                Kind = ClipKind.Image, ImagePath = $"images/{hash}.png", ImageWidth = img.Width, ImageHeight = img.Height,
                PreviewText = ClipText.ImagePreview(img.Width, img.Height), ContentHash = hash, SourceApp = raw.SourceProcess, CreatedAt = createdAt,
            };
            writeSidecar = it => WritePrivate(_repo.Resolve(it.ImagePath!), img.Png);
        }
        else if (raw.Text != null)
        {
            if (!s.KeepText || ClipText.IsBlank(raw.Text)) return;
            if (s.CharacterLimit is int lim && raw.Text.Length > lim) return;
            var hash = ClipText.Sha256(raw.Text);
            item = new ClipItem
            {
                Kind = ClipKind.Text, TextContent = raw.Text, PreviewText = ClipText.Preview(raw.Text),
                ContentHash = hash, SourceApp = raw.SourceProcess, CreatedAt = createdAt,
            };
            var rich = RichText(raw, hash);
            if (rich != null)
            {
                item.RichTextPath = rich.Value.Relative;
                writeSidecar = it => WritePrivate(_repo.Resolve(rich.Value.Relative), rich.Value.Bytes);
            }
        }
        if (item == null) return;

        var (stored, isNew) = _repo.InsertOrTouch(item, s.MoveToTopOnUse);
        if (isNew)
        {
            // Row first, then sidecar: every file on disk already has its row (the orphan sweep relies on it).
            if (writeSidecar != null)
            {
                try { writeSidecar(stored); }
                catch (Exception e)
                {
                    Debug.WriteLine($"sidecar write failed: {e.Message}");
                    if (stored.Kind == ClipKind.Image) _repo.Delete(stored.Id);
                    else _repo.UpdateText(stored.Id, stored.TextContent!, stored.ContentHash); // keep the text, drop formatting
                }
            }
            _retention.Trim();
        }
        else if (stored.Kind == ClipKind.Text && stored.RichTextPath == null && raw.Rtf != null && RichText(raw, stored.ContentHash) is { } r)
        {
            // A re-copy fills in formatting a row was stored without (native RTF only, like the Mac).
            try
            {
                WritePrivate(_repo.Resolve(r.Relative), r.Bytes);
                _repo.SetRichTextPath(stored.Id, r.Relative);
            }
            catch { /* keep plain */ }
        }
    }

    private static (string Relative, byte[] Bytes)? RichText(RawClipboard raw, string hash)
    {
        if (raw.Rtf is { Length: > 0 } rtf)
        {
            var end = Array.IndexOf(rtf, (byte)0);
            return ($"richtext/{hash}.rtf", end >= 0 ? rtf[..end] : rtf);
        }
        if (raw.Html is { Length: > 0 } html && CfHtml.ExtractFragment(html) is { } fragment)
        {
            var clean = HtmlSanitizer.Sanitize(fragment);
            return ($"richtext/{hash}.html", Encoding.UTF8.GetBytes(clean));
        }
        return null;
    }

    private static void WritePrivate(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, bytes);
    }
}

/// <summary>Writes history items/snippets to the clipboard and optionally pastes into the previous app.</summary>
internal sealed class Paster
{
    private readonly ClipboardRepository _repo;
    private readonly ClipboardMonitor _monitor;
    private readonly Func<ClipboardSettings> _settings;

    public Paster(ClipboardRepository repo, ClipboardMonitor monitor, Func<ClipboardSettings> settings)
    {
        _repo = repo;
        _monitor = monitor;
        _settings = settings;
    }

    public static bool SetClipboard(DataObject data)
    {
        for (var i = 0; i < 10; i++)
        {
            try
            {
                System.Windows.Clipboard.SetDataObject(data, true);
                return true;
            }
            catch (COMException) { Thread.Sleep(30); }
            catch (ExternalException) { Thread.Sleep(30); }
        }
        return false;
    }

    public DataObject BuildData(ClipItem item, bool plainText)
    {
        var data = new DataObject();
        switch (item.Kind)
        {
            case ClipKind.Text:
                data.SetText(item.TextContent ?? "", TextDataFormat.UnicodeText);
                if (!plainText && item.RichTextPath is { } rp)
                {
                    try
                    {
                        var bytes = File.ReadAllBytes(_repo.Resolve(rp));
                        if (rp.EndsWith(".rtf", StringComparison.OrdinalIgnoreCase))
                            data.SetData(DataFormats.Rtf, Encoding.Default.GetString(bytes));
                        else
                            data.SetData("HTML Format", new MemoryStream(CfHtml.Build(Encoding.UTF8.GetString(bytes))));
                    }
                    catch { /* sidecar gone: plain text still pastes */ }
                }
                break;
            case ClipKind.Image:
                if (item.ImagePath is { } ip && File.Exists(_repo.Resolve(ip)))
                {
                    var png = File.ReadAllBytes(_repo.Resolve(ip));
                    var bmp = new BitmapImage();
                    bmp.BeginInit();
                    bmp.CacheOption = BitmapCacheOption.OnLoad;
                    bmp.StreamSource = new MemoryStream(png);
                    bmp.EndInit();
                    bmp.Freeze();
                    data.SetImage(bmp);
                    data.SetData("PNG", new MemoryStream(png));
                }
                break;
            case ClipKind.File:
                var files = new StringCollection();
                foreach (var f in (item.TextContent ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries)) files.Add(f);
                data.SetFileDropList(files);
                break;
        }
        return data;
    }

    /// <summary>Writes a history item and pastes it into <paramref name="target"/>. Not re-captured.</summary>
    public void Paste(ClipItem item, IntPtr target, bool plainText = false, bool pasteIntoTarget = true)
    {
        if (!SetClipboard(BuildData(item, plainText))) return;
        _monitor.SuppressCurrent();
        var s = _settings();
        if (s.MoveToTopOnUse) _repo.Touch(item.Id, DateTime.Now);
        if (pasteIntoTarget && s.AutoPasteEnabled) SendPasteTo(target);
    }

    /// <summary>Writes snippet text and pastes it. Deliberately lands in history (like the Mac).</summary>
    public void PasteText(string text, IntPtr target, bool pasteIntoTarget = true)
    {
        var data = new DataObject();
        data.SetText(text, TextDataFormat.UnicodeText);
        if (!SetClipboard(data)) return;
        if (pasteIntoTarget && _settings().AutoPasteEnabled) SendPasteTo(target);
    }

    public static void CopyText(string text)
    {
        var data = new DataObject();
        data.SetText(text, TextDataFormat.UnicodeText);
        SetClipboard(data);
    }

    private static void SendPasteTo(IntPtr target)
    {
        if (target == IntPtr.Zero || Native.IsOwnWindow(target)) return;
        Native.ForceForeground(target);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            Native.SendPaste();
        };
        timer.Start();
    }
}

/// <summary>Double-tap Ctrl+C within 0.5 s appends the new copy onto the previous text item.</summary>
internal sealed class FastAppendService : IDisposable
{
    private readonly ClipboardRepository _repo;
    private readonly ClipboardMonitor _monitor;
    private readonly Func<ClipboardSettings> _settings;
    private readonly Native.LowLevelKeyboardProc _proc;
    private IntPtr _hook;
    private DateTime _lastCopy = DateTime.MinValue;

    public FastAppendService(ClipboardRepository repo, ClipboardMonitor monitor, Func<ClipboardSettings> settings)
    {
        _repo = repo;
        _monitor = monitor;
        _settings = settings;
        _proc = HookProc;
    }

    /// <summary>Installs or removes the keyboard hook to match the setting.</summary>
    public void Sync()
    {
        var want = _settings().FastAppendEnabled;
        if (want && _hook == IntPtr.Zero)
            _hook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _proc, Native.GetModuleHandle(null), 0);
        else if (!want && _hook != IntPtr.Zero)
        {
            Native.UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
    }

    private IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && (wParam == (IntPtr)Native.WM_KEYDOWN || wParam == (IntPtr)Native.WM_SYSKEYDOWN))
        {
            var k = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
            var ctrl = (Native.GetAsyncKeyState(0x11) & 0x8000) != 0;
            var injected = (k.flags & 0x10) != 0 && k.dwExtraInfo == Native.MukkerInputTag;
            if (k.vkCode == 0x43 && ctrl && !injected && (k.flags & 0x80) == 0)
            {
                var now = DateTime.UtcNow;
                if ((now - _lastCopy).TotalSeconds <= 0.5)
                {
                    _lastCopy = DateTime.MinValue;
                    // Return immediately: a low-level hook must not block. Merge once the copy is recorded.
                    Application.Current.Dispatcher.BeginInvoke(async () => await MergeAsync());
                }
                else _lastCopy = now;
            }
        }
        return Native.CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    private async Task MergeAsync()
    {
        await Task.Delay(120);
        // Wait (up to 1 s) until the monitor has processed the second copy.
        for (var i = 0; i < 20 && _monitor.ProcessedSequence != Native.GetClipboardSequenceNumber(); i++)
            await Task.Delay(50);
        string copied;
        try { copied = System.Windows.Clipboard.ContainsText() ? System.Windows.Clipboard.GetText() : ""; }
        catch { return; }
        if (ClipText.IsBlank(copied)) return;
        var s = _settings();
        if (!s.KeepText) return;
        var plan = FastAppend.Plan(_repo.NewestTexts(2), copied, s.SeparatorString);
        if (plan is not { } p) return;
        _repo.UpdateText(p.Target.Id, p.Merged, ClipText.Sha256(p.Merged));
        _repo.Touch(p.Target.Id, DateTime.Now);
        if (s.FastAppendBackToClipboard)
        {
            Paster.CopyText(p.Merged);
            _monitor.SuppressCurrent();
        }
        if (s.PlayAppendSound) System.Media.SystemSounds.Asterisk.Play();
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero) Native.UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }
}
