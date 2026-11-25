using System;
using System.Text.Json.Serialization;

namespace Mukker.Core.Settings;

/// <summary>All persisted preferences. Defaults mirror the macOS app.</summary>
public sealed class AppSettings
{
    public ClipboardSettings Clipboard { get; set; } = new();
    public CaptureSettings Capture { get; set; } = new();
    public ChimeSettings Chime { get; set; } = new();
    public TranslationSettings Translation { get; set; } = new();
    public ShortcutSettings Shortcuts { get; set; } = new();
    public DictationSettings Dictation { get; set; } = new();
    public bool StartWithWindows { get; set; } = false;
}

public enum Retention { Day, Week, Month, ThreeMonths, Year, Forever }

public enum AppendSeparator { None, Space, Newline }

public enum MaxClipSize { K64, K256, K512, M1, M2, Unlimited }

public sealed class IgnoredApp
{
    /// <summary>Executable name without extension, matched case-insensitively (e.g. "1Password").</summary>
    public string ProcessName { get; set; } = "";
    public string DisplayName { get; set; } = "";
}

public sealed class PasswordManagerExtension
{
    public string Name { get; set; } = "";
    public string ExtensionId { get; set; } = "";
}

public sealed class ClipboardSettings
{
    // Popup
    public double PopupSizePercent { get; set; } = 0.6;
    public bool PopupCustomBackgroundEnabled { get; set; } = true;
    public string PopupBackgroundColor { get; set; } = "#FFFFFFFF";
    public bool PopupBezelEnabled { get; set; } = true;
    public string PopupBezelColor { get; set; } = "#E69718FF"; // rgb(0.902, 0.592, 0.094)
    public double PopupBezelWidth { get; set; } = 7;

    // History
    public bool KeepText { get; set; } = true;
    public bool KeepImages { get; set; } = true;
    public bool KeepFiles { get; set; } = true;
    public Retention TextRetention { get; set; } = Retention.Month;
    public Retention ImageRetention { get; set; } = Retention.Month;
    public Retention FileRetention { get; set; } = Retention.Month;
    public bool MoveToTopOnUse { get; set; } = true;
    public int MaxHistoryItems { get; set; } = 1000;
    public bool AutoPasteEnabled { get; set; } = true;
    public bool HighlightSearchMatches { get; set; } = false;
    public bool PlainTextPreview { get; set; } = false;

    // Merging
    public bool FastAppendEnabled { get; set; } = false;
    public bool FastAppendBackToClipboard { get; set; } = true;
    public AppendSeparator AppendSeparator { get; set; } = AppendSeparator.Space;
    public bool PlayAppendSound { get; set; } = true;

    // Advanced
    public MaxClipSize MaxClipSize { get; set; } = MaxClipSize.K256;
    public bool IgnoreConcealedItems { get; set; } = true;
    public List<IgnoredApp> IgnoredApps { get; set; } = DefaultIgnoredApps();
    public List<PasswordManagerExtension> PasswordManagerExtensions { get; set; } = DefaultExtensions();
    public bool ForeverHistoryEnabled { get; set; } = false;
    public string? ForeverHistoryDirectory { get; set; }

    public static List<IgnoredApp> DefaultIgnoredApps() =>
    [
        new() { ProcessName = "1Password", DisplayName = "1Password" },
        new() { ProcessName = "Bitwarden", DisplayName = "Bitwarden" },
        new() { ProcessName = "KeePass", DisplayName = "KeePass" },
        new() { ProcessName = "KeePassXC", DisplayName = "KeePassXC" },
        new() { ProcessName = "LastPass", DisplayName = "LastPass" },
        new() { ProcessName = "CredentialUIBroker", DisplayName = "Windows Security" },
    ];

    public static List<PasswordManagerExtension> DefaultExtensions() =>
    [
        new() { Name = "1Password", ExtensionId = "aeblfdkhhhdcdjpifhhbdiojplfjncoa" },
        new() { Name = "Bitwarden", ExtensionId = "nngceckbapebfimnlniiiahkandclblb" },
        new() { Name = "LastPass", ExtensionId = "hdokiejnpimakedhajhdlcegeplioahd" },
        new() { Name = "Dashlane", ExtensionId = "fdjamakpfbbddfjaooikfcpapjohcfmg" },
        new() { Name = "Proton Pass", ExtensionId = "ghmbeldphafepmbegfdlkpapadhbakde" },
        new() { Name = "NordPass", ExtensionId = "eiaeiblijfjekdanodkjadfinkhbfgcd" },
        new() { Name = "Keeper", ExtensionId = "bfogiafebfohielmmehodmfbbebbbpei" },
        new() { Name = "RoboForm", ExtensionId = "pnlccmojcmeohlpggmfnbbiapkmbliob" },
    ];

    public TimeSpan? RetentionFor(ClipKind kind) => ToTimeSpan(kind switch
    {
        ClipKind.Text => TextRetention,
        ClipKind.Image => ImageRetention,
        _ => FileRetention,
    });

    public bool IsKindEnabled(ClipKind kind) => kind switch
    {
        ClipKind.Text => KeepText,
        ClipKind.Image => KeepImages,
        _ => KeepFiles,
    };

    public static TimeSpan? ToTimeSpan(Retention r) => r switch
    {
        Retention.Day => TimeSpan.FromDays(1),
        Retention.Week => TimeSpan.FromDays(7),
        Retention.Month => TimeSpan.FromDays(30),
        Retention.ThreeMonths => TimeSpan.FromDays(90),
        Retention.Year => TimeSpan.FromDays(365),
        _ => null,
    };

    /// <summary>Character limit for a clip; null = unlimited.</summary>
    [JsonIgnore]
    public int? CharacterLimit => MaxClipSize switch
    {
        MaxClipSize.K64 => 64 * 1024,
        MaxClipSize.K256 => 256 * 1024,
        MaxClipSize.K512 => 512 * 1024,
        MaxClipSize.M1 => 1024 * 1024,
        MaxClipSize.M2 => 2 * 1024 * 1024,
        _ => null,
    };

    public string SeparatorString => AppendSeparator switch
    {
        AppendSeparator.None => "",
        AppendSeparator.Newline => "\n",
        _ => " ",
    };
}

public enum ClipKind { Text, Image, File }

public enum AfterCapture { Show, Copy, Save }

public enum SaveFormat { Png, Jpeg }

public sealed class CaptureSettings
{
    public string? SaveDirectory { get; set; }
    public SaveFormat SaveFormat { get; set; } = SaveFormat.Png;
    public bool DownscaleToStandard { get; set; } = false;
    public AfterCapture AfterCapture { get; set; } = AfterCapture.Show;
    public bool ShowMagnifierDuringCapture { get; set; } = false;
    public bool CloseAfterCopy { get; set; } = true;
    public bool CloseAfterSave { get; set; } = true;
    public bool EscCopiesAndCloses { get; set; } = false;
    public int DefaultColorIndex { get; set; } = 0;
    public int DefaultTextColorIndex { get; set; } = 7;
    public double DefaultTextSize { get; set; } = 14;
    public double DefaultLineWidth { get; set; } = 2;
    public double CanvasPadding { get; set; } = 24;
    /// <summary>Tool name → single key override.</summary>
    public Dictionary<string, string> ToolShortcuts { get; set; } = new();
    public int ScrollMaxHeight { get; set; } = 20000;
    public double ScrollSpeed { get; set; } = 0.6;
}

/// <summary>The hourly chime — the one piece of the Mac calendar feature the Windows port keeps.</summary>
public sealed class ChimeSettings
{
    public bool HourlyChime { get; set; } = false;
    /// <summary>A .wav file name (without extension) from C:\Windows\Media.</summary>
    public string HourlyChimeSound { get; set; } = "Windows Notify System Generic";
    public int HourlyChimeStartHour { get; set; } = 9;
    public int HourlyChimeEndHour { get; set; } = 22;
}

public enum TranslationBackend { Codex, Claude }

public sealed class TranslationSettings
{
    public bool Enabled { get; set; } = true;
    public bool CopiesResult { get; set; } = true;
    public TranslationBackend Backend { get; set; } = TranslationBackend.Codex;
    public string CodexPath { get; set; } = "";
    public string CodexModel { get; set; } = "";
    public string ClaudePath { get; set; } = "";
    public string ClaudeModel { get; set; } = "sonnet";

    /// <summary>The result panel's size in DIPs (Settings → Translate → Panel, or dragging its edges).</summary>
    public double PanelWidth { get; set; } = DefaultPanelWidth;
    public double PanelHeight { get; set; } = DefaultPanelHeight;
    /// <summary>Where the user last dragged the panel (top-left, physical pixels); null until moved, which centres it on the cursor's screen.</summary>
    public double? PanelLeft { get; set; }
    public double? PanelTop { get; set; }

    /// <summary>A coloured border like the popup's bezel — same defaults and range, stored separately.</summary>
    public bool BorderEnabled { get; set; } = true;
    public string BorderColor { get; set; } = "#E69718FF";
    public double BorderWidth { get; set; } = 7;

    public const double DefaultPanelWidth = 560, DefaultPanelHeight = 380;
    public static readonly (double Min, double Max) PanelWidthRange = (380, 1200);
    public static readonly (double Min, double Max) PanelHeightRange = (260, 1000);
    public static readonly (double Min, double Max) BorderWidthRange = (0, 12);

    public static double Clamp(double value, (double Min, double Max) range) =>
        double.IsFinite(value) ? Math.Min(Math.Max(value, range.Min), range.Max) : range.Min;

    public double ClampedPanelWidth => Clamp(PanelWidth, PanelWidthRange);
    public double ClampedPanelHeight => Clamp(PanelHeight, PanelHeightRange);
    public double ClampedBorderWidth => Clamp(BorderWidth, BorderWidthRange);

    public string PathFor(TranslationBackend b) => b == TranslationBackend.Codex ? CodexPath : ClaudePath;
    public string ModelFor(TranslationBackend b) => b == TranslationBackend.Codex ? CodexModel : ClaudeModel;
}

[Flags]
public enum KeyModifiers { None = 0, Alt = 1, Control = 2, Shift = 4, Win = 8 }

public sealed record KeyCombo(KeyModifiers Modifiers, int VirtualKey)
{
    public override string ToString() => KeyNames.Describe(this);
}

public sealed class ShortcutSettings
{
    // Virtual-key codes: VK_SPACE=0x20, 'E'=0x45, 'H'=0x48, '3'..'5'=0x33..0x35
    public KeyCombo? Popup { get; set; } = new(KeyModifiers.Control | KeyModifiers.Shift, 0x20);
    public KeyCombo? Area { get; set; } = new(KeyModifiers.Control | KeyModifiers.Shift, 0x34);
    public KeyCombo? Fullscreen { get; set; } = new(KeyModifiers.Control | KeyModifiers.Shift, 0x33);
    public KeyCombo? Scrolling { get; set; } = new(KeyModifiers.Control | KeyModifiers.Shift, 0x35);
    public KeyCombo? TranslateEnglish { get; set; } = new(KeyModifiers.Control | KeyModifiers.Shift, 0x45);
    public KeyCombo? TranslateHungarian { get; set; } = new(KeyModifiers.Control | KeyModifiers.Shift, 0x48);
    public KeyCombo? TranslateGerman { get; set; } = new(KeyModifiers.Control | KeyModifiers.Shift, 0x47);

    public static ShortcutSettings Defaults() => new();

    /// <summary>A newly recorded combo needs Ctrl, Alt or Win (bare F1–F24 excepted), mirroring the Mac rule.</summary>
    public static bool IsAcceptable(KeyCombo combo)
    {
        if (combo.VirtualKey is >= 0x70 and <= 0x87) return true; // F1..F24
        return (combo.Modifiers & (KeyModifiers.Control | KeyModifiers.Alt | KeyModifiers.Win)) != 0;
    }
}

public static class KeyNames
{
    public static string Describe(KeyCombo c)
    {
        var parts = new List<string>();
        if (c.Modifiers.HasFlag(KeyModifiers.Control)) parts.Add("Ctrl");
        if (c.Modifiers.HasFlag(KeyModifiers.Alt)) parts.Add("Alt");
        if (c.Modifiers.HasFlag(KeyModifiers.Shift)) parts.Add("Shift");
        if (c.Modifiers.HasFlag(KeyModifiers.Win)) parts.Add("Win");
        parts.Add(KeyName(c.VirtualKey));
        return string.Join("+", parts);
    }

    public static string KeyName(int vk) => vk switch
    {
        >= 0x30 and <= 0x39 => ((char)vk).ToString(),
        >= 0x41 and <= 0x5A => ((char)vk).ToString(),
        >= 0x70 and <= 0x87 => $"F{vk - 0x6F}",
        >= 0x60 and <= 0x69 => $"Num{vk - 0x60}",
        0x20 => "Space",
        0x0D => "Enter",
        0x09 => "Tab",
        0x1B => "Esc",
        0x08 => "Backspace",
        0x2E => "Delete",
        0x2D => "Insert",
        0x24 => "Home",
        0x23 => "End",
        0x21 => "PageUp",
        0x22 => "PageDown",
        0x25 => "Left",
        0x26 => "Up",
        0x27 => "Right",
        0x28 => "Down",
        0x2C => "PrintScreen",
        0xBA => ";",
        0xBB => "=",
        0xBC => ",",
        0xBD => "-",
        0xBE => ".",
        0xBF => "/",
        0xC0 => "`",
        0xDB => "[",
        0xDC => "\\",
        0xDD => "]",
        0xDE => "'",
        _ => $"0x{vk:X2}",
    };
}
