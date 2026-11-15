using System;
using System.Linq;
using System.Media;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Threading;
using Mukker.App.Clipboard;
using Mukker.App.Interop;
using Mukker.Core.Clipboard;
using Mukker.Core.Translate;

namespace Mukker.App.Translate;

/// <summary>
/// Reads the focused app's selection through UI Automation — never by simulating Ctrl+C, which would put
/// the text on the clipboard (where other clipboard tools see it) and trigger fast append.
///
/// <para><b>Chromium-based apps</b> (Chrome, Edge, Brave and every Electron app; their top-level windows are
/// <c>Chrome_WidgetWin_*</c>) build their accessibility tree only once a UIA client asks for it, so the first
/// read finds a focused element without a text pattern. The read itself is that request, so <see cref="Read"/>
/// reports <see cref="Outcome.Waking"/> and the caller polls <see cref="PollAsync"/> while the tree appears
/// (a second or two). Once built the tree stays, so only the first press in each app process waits.</para>
/// </summary>
internal static class SelectionReader
{
    public sealed record Selection(string Text, string? ProcessName);

    public abstract record Outcome
    {
        public sealed record Found(Selection Selection) : Outcome;
        public sealed record Nothing(string Reason) : Outcome;
        /// <summary>A Chromium app with no accessibility tree yet; poll <see cref="PollAsync"/> for <paramref name="ProcessId"/>.</summary>
        public sealed record Waking(int ProcessId, string? ProcessName) : Outcome;
    }

    public enum PollResult { Pending, Found, Nothing }

    private static readonly TimeSpan Budget = TimeSpan.FromMilliseconds(500);

    /// <summary>What the focused element offers: its process, whether it has a text pattern, and the selected text.</summary>
    private readonly record struct Probe(bool Answered, int ProcessId, bool HasTextPattern, string? Text);

    private static Probe ProbeFocused()
    {
        try
        {
            var el = AutomationElement.FocusedElement;
            if (el == null) return new Probe(true, 0, false, null);
            var pid = el.Current.ProcessId;
            if (pid == Environment.ProcessId) return new Probe(true, pid, false, null);
            if (el.TryGetCurrentPattern(TextPattern.Pattern, out var p) && p is TextPattern tp)
            {
                var text = string.Concat(tp.GetSelection().Select(r => r.GetText(-1)));
                return new Probe(true, pid, true, string.IsNullOrWhiteSpace(text) ? null : text);
            }
            return new Probe(true, pid, false, null);
        }
        catch { return new Probe(true, 0, false, null); }
    }

    /// <summary>Runs the probe on a worker with a 0.5 s budget, so a hung app can't freeze us.</summary>
    private static async Task<Probe> ProbeAsync()
    {
        var task = Task.Run(ProbeFocused);
        return await Task.WhenAny(task, Task.Delay(Budget)) == task ? task.Result : default;
    }

    private static Probe ProbeBlocking()
    {
        var task = Task.Run(ProbeFocused);
        return task.Wait(Budget) ? task.Result : default;
    }

    public static bool IsChromiumWindow(IntPtr hwnd) => Native.ClassNameOf(hwnd).StartsWith("Chrome_WidgetWin_", StringComparison.Ordinal);

    /// <summary>The selection of the foreground app. Must run before anything of ours takes focus.</summary>
    public static Outcome Read()
    {
        var fg = Native.GetForegroundWindow();
        if (fg == IntPtr.Zero) return new Outcome.Nothing("no foreground window");
        if (Native.IsOwnWindow(fg)) return new Outcome.Nothing("own window");
        var process = Native.ProcessNameOfWindow(fg);
        var probe = ProbeBlocking();
        if (!probe.Answered) return new Outcome.Nothing("timed out");
        if (probe.Text is { } text) return new Outcome.Found(new Selection(text, process));
        if (!probe.HasTextPattern && IsChromiumWindow(fg)) return new Outcome.Waking(Native.ProcessIdOf(fg), process);
        return new Outcome.Nothing(probe.HasTextPattern ? "nothing selected" : "no text pattern");
    }

    /// <summary>
    /// One poll after <see cref="Outcome.Waking"/>: the focused element of <paramref name="processId"/>, if focus is
    /// still there. The panel is shown without activation while this runs, so the app keeps its focus.
    /// </summary>
    public static async Task<(PollResult Result, string? Text)> PollAsync(int processId)
    {
        var probe = await ProbeAsync();
        if (!probe.Answered || probe.ProcessId != processId) return (PollResult.Pending, null);
        if (probe.Text != null) return (PollResult.Found, probe.Text);
        // A text pattern with nothing selected is a real answer; no pattern yet means the tree is still building.
        return (probe.HasTextPattern ? PollResult.Nothing : PollResult.Pending, null);
    }
}

internal abstract record PanelState(TranslationLanguage Language)
{
    /// <summary>Waiting for a Chromium app to build its accessibility tree ("Reading the selection…").</summary>
    public sealed record Reading(TranslationLanguage Language) : PanelState(Language);
    public sealed record Translating(TranslationLanguage Language, string Source) : PanelState(Language);
    public sealed record Done(TranslationLanguage Language, string Source, string Result) : PanelState(Language);
    public sealed record Failed(TranslationLanguage Language, string Source, string Message) : PanelState(Language);

    /// <summary>The text that was sent ("" while reading, or for a failure with nothing to send).</summary>
    public string SentText => this switch
    {
        Translating t => t.Source,
        Done d => d.Source,
        Failed f => f.Source,
        _ => "",
    };

    public bool IsBusy => this is Reading or Translating;
}

/// <summary>
/// Owns the translate panel. It opens at once on the hotkey (the answer takes seconds) and closes on Esc,
/// Ctrl+W, Close or the same language's hotkey — except that Esc and the hotkeys leave it up while the source
/// field holds text the user typed and hasn't translated yet (<see cref="IsDraftEdited"/>).
/// </summary>
internal sealed class TranslationController
{
    /// <summary>How long a just-woken Chromium app gets to build its tree, and how often it is asked meanwhile.</summary>
    private static readonly TimeSpan SelectionWakeTimeout = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan SelectionPollInterval = TimeSpan.FromMilliseconds(150);

    private readonly AppHost _host;
    private TranslationPanel? _panel;
    private CancellationTokenSource? _cts;
    private DispatcherTimer? _selectionPoll;
    private int _generation;
    private DateTime _lastRequest = DateTime.MinValue;
    private IntPtr _previous;

    public PanelState? State { get; private set; }
    public TranslationOrigin Origin { get; private set; }

    /// <summary>
    /// The panel's editable source field. Reset to the source by every request; anything typed or pasted into it
    /// differs from <see cref="PanelState.SentText"/> until translated.
    /// </summary>
    public string Draft { get; set; } = "";

    public bool IsDraftEdited => Draft != (State?.SentText ?? "");

    public TranslationController(AppHost host)
    {
        _host = host;
        _host.Settings.Changed += (_, _) => Application.Current?.Dispatcher.BeginInvoke(() => _panel?.ApplySettings());
    }

    public void Request(TranslationLanguage language)
    {
        var now = DateTime.UtcNow;
        if ((now - _lastRequest).TotalMilliseconds < 200) return; // debounce key repeat
        _lastRequest = now;

        if (_panel is { IsVisible: true } panel)
        {
            // Typed text wins over everything: the hotkey translates it.
            if (IsDraftEdited)
            {
                TranslateDraft(language);
                return;
            }
            if (State?.Language == language)
            {
                Close();
                return;
            }
            // With the panel focused there is no selection elsewhere to read, and history's newest entry is by
            // now the translation itself — so the other language's hotkey re-sends what is shown.
            if (panel.IsForeground)
            {
                TranslateDraft(language);
                return;
            }
        }

        // Read the selection before the panel takes focus away from it.
        var fg = Native.GetForegroundWindow();
        if (!Native.IsOwnWindow(fg)) _previous = fg;
        switch (SelectionReader.Read())
        {
            case SelectionReader.Outcome.Found f:
                TranslateSelectionOrLatest(language, f.Selection);
                break;
            case SelectionReader.Outcome.Waking w:
                AwaitSelection(w.ProcessId, w.ProcessName, language);
                break;
            case SelectionReader.Outcome.Nothing n:
                AppHost.Log($"translate: no selection ({n.Reason})");
                TranslateSelectionOrLatest(language, null);
                break;
        }
    }

    /// <summary>
    /// Polls a Chromium app that is building its accessibility tree, for up to <see cref="SelectionWakeTimeout"/>,
    /// then translates what it found or falls back to history. The panel shows "Reading the selection…" without
    /// taking focus meanwhile, so the selection stays focused in the app.
    /// </summary>
    private void AwaitSelection(int processId, string? processName, TranslationLanguage language)
    {
        Cancel();
        var gen = _generation;
        Origin = TranslationOrigin.Selection;
        Draft = "";
        AppHost.Log($"translate: waiting for pid {processId} to build its accessibility tree");
        SetState(new PanelState.Reading(language), activate: false);
        var deadline = DateTime.UtcNow + SelectionWakeTimeout;
        var busy = false;
        var timer = _selectionPoll = new DispatcherTimer { Interval = SelectionPollInterval };
        timer.Tick += async (_, _) =>
        {
            if (busy) return;
            if (gen != _generation)
            {
                timer.Stop();
                return;
            }
            busy = true;
            var (result, text) = await SelectionReader.PollAsync(processId);
            busy = false;
            if (gen != _generation) return;
            if (result == SelectionReader.PollResult.Pending && DateTime.UtcNow < deadline) return;
            timer.Stop();
            _selectionPoll = null;
            if (result != SelectionReader.PollResult.Found) AppHost.Log($"translate: no selection after waiting ({result})");
            TranslateSelectionOrLatest(language, text != null ? new SelectionReader.Selection(text, processName) : null);
        };
        timer.Start();
    }

    /// <summary>The selection, unless it comes from an ignored app; otherwise the newest text in history.</summary>
    private void TranslateSelectionOrLatest(TranslationLanguage language, SelectionReader.Selection? selection)
    {
        var clip = _host.Settings.Current.Clipboard;
        if (selection?.ProcessName is { } proc && CapturePolicy.IsIgnoredApp(proc, clip))
        {
            AppHost.Log($"translate: selection in ignored app {proc} not used");
            selection = null;
        }

        var newest = _host.Clips.NewestText();
        switch (SourceDecision.Decide(selection?.Text, newest, clip.CharacterLimit))
        {
            case SourceDecision.FromSelection s:
                AppHost.Log("translate source: selection");
                Translate(s.Text, language, TranslationOrigin.Selection);
                break;
            case SourceDecision.FromHistory h when !ClipText.IsBlank(h.Item.TextContent):
                AppHost.Log("translate source: clipboard history");
                Translate(h.Item.TextContent!, language, TranslationOrigin.History);
                break;
            case SourceDecision.SelectionTooLong t:
                Fail(TranslationErrors.SelectionTooLong(t.Count, t.Limit), language, TranslationOrigin.Selection);
                break;
            default:
                Fail(TranslationErrors.NothingToTranslate, language, TranslationOrigin.History);
                break;
        }
    }

    private void Fail(string message, TranslationLanguage language, TranslationOrigin origin)
    {
        Cancel();
        Origin = origin;
        Draft = "";
        SetState(new PanelState.Failed(language, "", message));
    }

    /// <summary>Translates the panel's source field — edited or not — into <paramref name="language"/>.</summary>
    public void TranslateDraft(TranslationLanguage language)
    {
        var text = Draft;
        if (ClipText.IsBlank(text)) return;
        Translate(text, language, IsDraftEdited ? TranslationOrigin.Edited : Origin);
    }

    /// <summary>Ctrl+Enter: the source field again, into the last request's language.</summary>
    public void Submit()
    {
        if (State is { IsBusy: true }) return;
        TranslateDraft(State?.Language ?? TranslationLanguage.English);
    }

    public void Translate(string text, TranslationLanguage language, TranslationOrigin origin)
    {
        Cancel();
        Origin = origin;
        Draft = text;
        var gen = ++_generation;
        var cts = _cts = new CancellationTokenSource();
        SetState(new PanelState.Translating(language, text));
        var settings = _host.Settings.Current.Translation;
        var copies = settings.CopiesResult;
        AppHost.Log($"translate start: {text.Length} chars -> {language} via {settings.Backend}");
        _ = Task.Run(async () =>
        {
            TranslationOutcome outcome;
            try { outcome = await CliRunner.TranslateAsync(settings, new CliLocator(), language, text, cts.Token); }
            catch (OperationCanceledException) { return; }
            catch (Exception e) { outcome = new TranslationOutcome.Failure(e.Message); }
            Application.Current.Dispatcher.Invoke(() =>
            {
                if (gen != _generation) return; // superseded
                switch (outcome)
                {
                    case TranslationOutcome.Success s:
                        AppHost.Log($"translate done: {s.Text.Length} chars");
                        // Deliberately not suppressed: the translation lands in history like any copy.
                        if (copies) Paster.CopyText(s.Text);
                        SetState(new PanelState.Done(language, text, s.Text));
                        break;
                    case TranslationOutcome.Failure f:
                        AppHost.Log("translate failed");
                        SetState(new PanelState.Failed(language, text, f.Message));
                        break;
                }
            });
        });
    }

    private void SetState(PanelState state, bool activate = true)
    {
        State = state;
        if (_panel == null)
        {
            _panel = new TranslationPanel(this, _host);
            _panel.Closed += (_, _) => _panel = null;
        }
        _panel.Render(state, Origin, _host.Settings.Current.Translation.Backend);
        if (!_panel.IsVisible) _panel.ShowPlaced(activate);
        else if (activate) _panel.ActivateIfInactive();
    }

    /// <summary>Esc: closes, unless the source field holds untranslated edits — Ctrl+W or Close discard those.</summary>
    public void Escape()
    {
        if (IsDraftEdited)
        {
            SystemSounds.Beep.Play();
            return;
        }
        Close();
    }

    public void Cancel()
    {
        _generation++;
        _selectionPoll?.Stop();
        _selectionPoll = null;
        try { _cts?.Cancel(); } catch { }
        _cts = null;
    }

    public void Close()
    {
        Cancel();
        _panel?.Close();
        _panel = null;
        State = null;
        Draft = "";
        if (_previous != IntPtr.Zero) Native.ForceForeground(_previous);
    }
}
