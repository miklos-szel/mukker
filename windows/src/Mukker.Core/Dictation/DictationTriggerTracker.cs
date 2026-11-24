using Mukker.Core.Settings;

namespace Mukker.Core.Dictation;

/// <summary>Which trigger fired: the base trigger (Ctrl+Win chord or custom combo) or a per-language combo.</summary>
public readonly record struct DictationTriggerId(DictationLanguage? Language)
{
    public static readonly DictationTriggerId Base = new(null);
    public static DictationTriggerId ForLanguage(DictationLanguage l) => new(l);
    public bool IsBase => Language is null;
}

public enum TriggerEventKind { Press, Release, Interrupt }

/// <summary>One event for the press machine. <see cref="Time"/> is the time passed to <c>Process</c>.</summary>
public readonly record struct TriggerEvent(TriggerEventKind Kind, DictationTriggerId Trigger, double Time);

/// <summary>
/// What a key event produced. <see cref="Events"/> is usually empty or one event; it holds two when a
/// language combo is pressed on top of a pressed Ctrl+Win chord (<c>[Interrupt(Base), Press(Language)]</c>) —
/// the App side must reset/cancel its press machine after the Interrupt, then feed the Press, and must NOT
/// expect a Release for the chord afterwards.
/// </summary>
/// <param name="Swallow">The hook must not pass this key event on.</param>
/// <param name="NeedsStartMenuGuard">A Win key-up that ends a chord press: inject a dummy key before letting it through, or the Start menu opens.</param>
public readonly record struct TriggerResult(IReadOnlyList<TriggerEvent> Events, bool Swallow, bool NeedsStartMenuGuard)
{
    public static readonly TriggerResult None = new(Array.Empty<TriggerEvent>(), false, false);
}

/// <summary>Which triggers are live. Build with <see cref="FromSettings"/>.</summary>
/// <param name="BaseCombo">The base trigger when it is a custom combo; null = the base trigger is the Ctrl+Win chord
/// (use <see cref="NoBase"/> for neither).</param>
public sealed record DictationTriggerConfig(
    DictationTrigger Base, KeyCombo? BaseCombo,
    KeyCombo? English = null, KeyCombo? German = null, KeyCombo? Hungarian = null)
{
    public static DictationTriggerConfig FromSettings(DictationSettings s) =>
        s.LanguageCombosActive
            ? new(s.Trigger, s.Combo, s.EnglishCombo, s.GermanCombo, s.HungarianCombo)
            : new(s.Trigger, s.Combo);

    public bool NoBase => Base == DictationTrigger.Combo && BaseCombo is null;
}

/// <summary>
/// Pure state machine behind the WH_KEYBOARD_LL hook. The App side feeds every key event that is not its own
/// injected input; the tracker keeps its own held-key set (left/right and generic modifier codes are folded
/// together) and reports presses, releases and interrupts of the configured triggers.
/// <para>Ctrl+Win chord: Press when Ctrl and Win are both down and nothing else is held; Release when either goes up
/// (once, also after an Interrupt); any other key going down while pressed is an Interrupt; after that the chord stays
/// consumed until both keys are up. Nothing is swallowed.</para>
/// <para>Combos: Press when the main key goes down with exactly the combo's modifiers and no other key held; the
/// key-down, its auto-repeats and its key-up are swallowed. Release when the main key or a required modifier goes up
/// (once, also after an Interrupt); another non-modifier key going down while held is an Interrupt.</para>
/// Not thread-safe; call from the hook thread only.
/// </summary>
public sealed class DictationTriggerTracker
{
    public const int VkShift = 0x10, VkControl = 0x11, VkMenu = 0x12;
    public const int VkLShift = 0xA0, VkRShift = 0xA1, VkLControl = 0xA2, VkRControl = 0xA3, VkLMenu = 0xA4, VkRMenu = 0xA5;
    public const int VkLWin = 0x5B, VkRWin = 0x5C;

    private enum Chord { Idle, Pressed, Interrupted, Consumed }

    private sealed class ActiveCombo
    {
        public required DictationTriggerId Id;
        public required KeyCombo Combo;
        public bool Interrupted;
    }

    private DictationTriggerConfig _config;
    private readonly HashSet<int> _held = [];
    private readonly HashSet<int> _swallowed = [];
    private Chord _chord = Chord.Idle;
    private bool _winInChord;
    private ActiveCombo? _active;

    public DictationTriggerTracker(DictationTriggerConfig config) => _config = config;

    /// <summary>Replaces the configuration and forgets any in-flight press (the App resets its press machine too).</summary>
    public void Reconfigure(DictationTriggerConfig config)
    {
        _config = config;
        Reset();
    }

    /// <summary>Forgets held keys and any press, e.g. after a desktop switch where key-ups were missed.</summary>
    public void Reset()
    {
        _held.Clear();
        _swallowed.Clear();
        _chord = Chord.Idle;
        _winInChord = false;
        _active = null;
    }

    public static int Normalize(int vk) => vk switch
    {
        VkShift => VkLShift,
        VkControl => VkLControl,
        VkMenu => VkLMenu,
        _ => vk,
    };

    private static bool IsModifier(int vk) => vk is VkLShift or VkRShift or VkLControl or VkRControl or VkLMenu or VkRMenu or VkLWin or VkRWin;
    private static bool IsCtrlOrWin(int vk) => vk is VkLControl or VkRControl or VkLWin or VkRWin;
    private static bool IsWin(int vk) => vk is VkLWin or VkRWin;

    private KeyModifiers HeldModifiers()
    {
        var m = KeyModifiers.None;
        if (_held.Contains(VkLControl) || _held.Contains(VkRControl)) m |= KeyModifiers.Control;
        if (_held.Contains(VkLMenu) || _held.Contains(VkRMenu)) m |= KeyModifiers.Alt;
        if (_held.Contains(VkLShift) || _held.Contains(VkRShift)) m |= KeyModifiers.Shift;
        if (_held.Contains(VkLWin) || _held.Contains(VkRWin)) m |= KeyModifiers.Win;
        return m;
    }

    private static TriggerResult Of(double time, bool swallow, bool guard, params (TriggerEventKind, DictationTriggerId)[] events) =>
        new(events.Select(e => new TriggerEvent(e.Item1, e.Item2, time)).ToArray(), swallow, guard);

    private IEnumerable<(DictationTriggerId Id, KeyCombo Combo)> Combos()
    {
        if (_config.Base == DictationTrigger.Combo && _config.BaseCombo is { } b) yield return (DictationTriggerId.Base, b);
        if (_config.English is { } e) yield return (DictationTriggerId.ForLanguage(DictationLanguage.English), e);
        if (_config.German is { } g) yield return (DictationTriggerId.ForLanguage(DictationLanguage.German), g);
        if (_config.Hungarian is { } h) yield return (DictationTriggerId.ForLanguage(DictationLanguage.Hungarian), h);
    }

    private (DictationTriggerId Id, KeyCombo Combo)? MatchCombo(int vk)
    {
        var mods = HeldModifiers();
        foreach (var (id, combo) in Combos())
            if (combo.VirtualKey == vk && combo.Modifiers == mods) return (id, combo);
        return null;
    }

    private bool OnlyHeldKeyIs(int vk) => _held.All(k => k == vk || IsModifier(k));

    /// <summary>Feeds one key event; <paramref name="time"/> is seconds on a monotonic clock.</summary>
    public TriggerResult Process(int vk, bool down, double time)
    {
        vk = Normalize(vk);
        return down ? KeyDown(vk, time) : KeyUp(vk, time);
    }

    private TriggerResult KeyDown(int vk, double time)
    {
        if (_held.Contains(vk))
            return _swallowed.Contains(vk) ? new TriggerResult(Array.Empty<TriggerEvent>(), true, false) : TriggerResult.None; // auto-repeat
        _held.Add(vk);

        var isMod = IsModifier(vk);

        // A pressed chord plus any key that is not Ctrl/Win.
        if (_chord == Chord.Pressed && !IsCtrlOrWin(vk))
        {
            if (!isMod && MatchCombo(vk) is { } hit && hit.Id.Language is not null && _active is null)
            {
                _chord = Chord.Consumed; // handed over: no Release(Base) will follow
                _active = new ActiveCombo { Id = hit.Id, Combo = hit.Combo };
                _swallowed.Add(vk);
                return Of(time, true, false, (TriggerEventKind.Interrupt, DictationTriggerId.Base), (TriggerEventKind.Press, hit.Id));
            }
            _chord = Chord.Interrupted;
            return Of(time, false, false, (TriggerEventKind.Interrupt, DictationTriggerId.Base));
        }

        if (_config.Base == DictationTrigger.CtrlWin && IsCtrlOrWin(vk) && _chord == Chord.Idle)
        {
            var mods = HeldModifiers();
            if (mods.HasFlag(KeyModifiers.Control) && mods.HasFlag(KeyModifiers.Win) && _held.All(IsCtrlOrWin))
            {
                _chord = Chord.Pressed;
                _winInChord = true;
                return Of(time, false, false, (TriggerEventKind.Press, DictationTriggerId.Base));
            }
        }

        if (isMod) return TriggerResult.None;

        if (_active is { } active)
        {
            if (!active.Interrupted)
            {
                active.Interrupted = true;
                return Of(time, false, false, (TriggerEventKind.Interrupt, active.Id));
            }
            return TriggerResult.None;
        }

        if (OnlyHeldKeyIs(vk) && MatchCombo(vk) is { } m)
        {
            _active = new ActiveCombo { Id = m.Id, Combo = m.Combo };
            _swallowed.Add(vk);
            return Of(time, true, false, (TriggerEventKind.Press, m.Id));
        }
        return TriggerResult.None;
    }

    private TriggerResult KeyUp(int vk, double time)
    {
        _held.Remove(vk);
        var swallow = _swallowed.Remove(vk);
        var guard = false;
        var events = new List<TriggerEvent>();

        if (IsWin(vk) && _winInChord)
        {
            guard = true;
            if (!_held.Contains(VkLWin) && !_held.Contains(VkRWin)) _winInChord = false;
        }

        if (_chord != Chord.Idle && IsCtrlOrWin(vk))
        {
            var ctrl = _held.Contains(VkLControl) || _held.Contains(VkRControl);
            var win = _held.Contains(VkLWin) || _held.Contains(VkRWin);
            if (_chord is Chord.Pressed or Chord.Interrupted)
            {
                if (!ctrl || !win)
                {
                    events.Add(new(TriggerEventKind.Release, DictationTriggerId.Base, time));
                    _chord = Chord.Consumed;
                }
            }
            if (_chord == Chord.Consumed && !ctrl && !win) _chord = Chord.Idle;
        }

        if (_active is { } a)
        {
            var lostModifier = IsModifier(vk) && (HeldModifiers() & a.Combo.Modifiers) != a.Combo.Modifiers;
            if (vk == a.Combo.VirtualKey || lostModifier)
            {
                events.Add(new(TriggerEventKind.Release, a.Id, time));
                _active = null;
            }
        }

        return new TriggerResult(events.Count == 0 ? Array.Empty<TriggerEvent>() : events, swallow, guard);
    }
}
