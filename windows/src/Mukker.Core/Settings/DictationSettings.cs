using System.Globalization;
using System.Text.Json.Serialization;
using Mukker.Core.Dictation;

namespace Mukker.Core.Settings;

/// <summary>What starts dictation. Windows has no fn key: the default is the Ctrl+Win chord.</summary>
public enum DictationTrigger { CtrlWin, Combo }

/// <summary>How a press of the trigger maps onto recording.</summary>
public enum DictationActivation { HoldOrToggle, PushToTalk, Toggle }

/// <summary>How long a loaded model stays in memory after the last dictation (seconds; -1 = never).</summary>
public enum DictationUnloadDelay
{
    Immediately = 0,
    TwoMinutes = 120,
    FiveMinutes = 300,
    FifteenMinutes = 900,
    OneHour = 3600,
    Never = -1,
}

public static class DictationLabels
{
    public static string Label(this DictationTrigger t) => t switch
    {
        DictationTrigger.CtrlWin => "Ctrl + Win",
        _ => "Custom shortcut",
    };

    public static string Label(this DictationActivation a) => a switch
    {
        DictationActivation.HoldOrToggle => "Hold to talk, or tap to start/stop",
        DictationActivation.PushToTalk => "Hold to talk",
        _ => "Tap to start, tap again to stop",
    };

    public static string Label(this DictationUnloadDelay d) => d switch
    {
        DictationUnloadDelay.Immediately => "Immediately",
        DictationUnloadDelay.TwoMinutes => "After 2 minutes",
        DictationUnloadDelay.FiveMinutes => "After 5 minutes",
        DictationUnloadDelay.FifteenMinutes => "After 15 minutes",
        DictationUnloadDelay.OneHour => "After 1 hour",
        _ => "Never",
    };
}

/// <summary>Preferences for Dictation. Defaults mirror the Mac, except the trigger (no fn key on Windows).</summary>
public sealed class DictationSettings
{
    public const double HoldThreshold = 0.3;

    public bool Enabled { get; set; } = true;
    public DictationTrigger Trigger { get; set; } = DictationTrigger.CtrlWin;
    /// <summary>Used when <see cref="Trigger"/> is <see cref="DictationTrigger.Combo"/>. Mirrors the Mac's ⌥Space.</summary>
    public KeyCombo? Combo { get; set; } = new(KeyModifiers.Alt, 0x20);
    public DictationActivation Activation { get; set; } = DictationActivation.HoldOrToggle;
    public string ModelId { get; set; } = DictationCatalog.DefaultModelId;
    /// <summary>Null is "Automatic".</summary>
    public DictationLanguage? Language { get; set; }
    /// <summary>The languages the user speaks; Automatic only chooses among these.</summary>
    public List<DictationLanguage> PreferredLanguages { get; set; } = DefaultPreferredLanguages(SystemLanguages());
    /// <summary>A device id from the audio API; empty follows the system default input.</summary>
    public string MicrophoneId { get; set; } = "";
    public bool SoundsEnabled { get; set; } = true;

    private double _soundVolume = 0.6;
    public double SoundVolume
    {
        get => _soundVolume;
        set => _soundVolume = double.IsFinite(value) ? Math.Min(Math.Max(value, 0), 1) : 0.6;
    }

    public bool OverlayEnabled { get; set; } = true;
    public bool AppendTrailingSpace { get; set; } = false;
    public DictationUnloadDelay UnloadDelay { get; set; } = DictationUnloadDelay.FiveMinutes;

    /// <summary>Per-language shortcuts: each starts a recording forced to that language. Null = not set.</summary>
    public KeyCombo? EnglishCombo { get; set; }
    public KeyCombo? GermanCombo { get; set; }
    public KeyCombo? HungarianCombo { get; set; }

    /// <summary>The selected model; an unknown stored id resolves to the default.</summary>
    [JsonIgnore]
    public DictationModel Model => DictationCatalog.Model(ModelId);

    /// <summary>The per-language shortcuts only work while the model takes a language hint.</summary>
    [JsonIgnore]
    public bool LanguageCombosActive => Enabled && Model.HonoursLanguage;

    public KeyCombo? ComboFor(DictationLanguage l) => l switch
    {
        DictationLanguage.English => EnglishCombo,
        DictationLanguage.German => GermanCombo,
        _ => HungarianCombo,
    };

    /// <summary>English plus the system languages that are among the three, in catalog order.</summary>
    public static List<DictationLanguage> DefaultPreferredLanguages(IEnumerable<string> systemLanguages)
    {
        var result = new HashSet<DictationLanguage> { DictationLanguage.English };
        foreach (var id in systemLanguages)
        {
            var code = id.Length >= 2 ? id[..2].ToLowerInvariant() : id;
            if (DictationLanguageExtensions.FromCode(code) is { } l) result.Add(l);
        }
        return Enum.GetValues<DictationLanguage>().Where(result.Contains).ToList();
    }

    private static IEnumerable<string> SystemLanguages() => [CultureInfo.CurrentUICulture.Name];
}
