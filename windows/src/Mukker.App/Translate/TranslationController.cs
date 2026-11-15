using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using Mukker.App.Clipboard;
using Mukker.App.Interop;
using Mukker.Core.Clipboard;
using Mukker.Core.Translate;

namespace Mukker.App.Translate;

/// <summary>
/// Reads the focused app's selection through UI Automation — never by simulating Ctrl+C, which would put
/// the text on the clipboard (where other clipboard tools see it) and trigger fast append.
/// </summary>
internal static class SelectionReader
{
    public sealed record Selection(string Text, string? ProcessName);

    /// <summary>The selected text, or null. Runs on a worker thread with a 0.5 s budget so a hung app can't freeze us.</summary>
    public static Selection? Read()
    {
        var fg = Native.GetForegroundWindow();
        if (fg == IntPtr.Zero || Native.IsOwnWindow(fg)) return null;
        var process = Native.ProcessNameOfWindow(fg);
        var task = Task.Run(() =>
        {
            try
            {
                var el = AutomationElement.FocusedElement;
                if (el == null) return null;
                if (el.Current.ProcessId == Environment.ProcessId) return null;
                if (el.TryGetCurrentPattern(TextPattern.Pattern, out var p) && p is TextPattern tp)
                {
                    var ranges = tp.GetSelection();
                    var text = string.Concat(ranges.Select(r => r.GetText(-1)));
                    return string.IsNullOrWhiteSpace(text) ? null : text;
                }
                return null;
            }
            catch { return null; }
        });
        if (!task.Wait(TimeSpan.FromMilliseconds(500))) return null;
        return task.Result is { } t ? new Selection(t, process) : null;
    }
}

internal abstract record PanelState(TranslationLanguage Language)
{
    public sealed record Translating(TranslationLanguage Language, string Source) : PanelState(Language);
    public sealed record Done(TranslationLanguage Language, string Source, string Result) : PanelState(Language);
    public sealed record Failed(TranslationLanguage Language, string Source, string Message) : PanelState(Language);
}

internal sealed class TranslationController
{
    private readonly AppHost _host;
    private TranslationPanel? _panel;
    private CancellationTokenSource? _cts;
    private int _generation;
    private DateTime _lastRequest = DateTime.MinValue;
    private IntPtr _previous;

    public PanelState? State { get; private set; }
    public TranslationOrigin Origin { get; private set; }

    public TranslationController(AppHost host) => _host = host;

    public void Request(TranslationLanguage language)
    {
        var now = DateTime.UtcNow;
        if ((now - _lastRequest).TotalMilliseconds < 200) return; // debounce key repeat
        _lastRequest = now;

        // Same language's hotkey while its panel is up closes it; the other language re-translates.
        if (_panel is { IsVisible: true } && State?.Language == language)
        {
            Close();
            return;
        }

        // Read the selection before the panel takes focus away from it.
        var fg = Native.GetForegroundWindow();
        if (!Native.IsOwnWindow(fg)) _previous = fg;
        var selection = Native.IsOwnWindow(fg) ? null : SelectionReader.Read();
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
        SetState(new PanelState.Failed(language, "", message));
    }

    /// <summary>Translates <paramref name="text"/>; also the panel's other-language button, which passes the original source.</summary>
    public void Translate(string text, TranslationLanguage language, TranslationOrigin origin)
    {
        Cancel();
        Origin = origin;
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

    private void SetState(PanelState state)
    {
        State = state;
        if (_panel == null)
        {
            _panel = new TranslationPanel(this, _host);
            _panel.Closed += (_, _) => _panel = null;
        }
        _panel.Render(state, Origin, _host.Settings.Current.Translation.Backend);
        if (!_panel.IsVisible) _panel.ShowCentered();
    }

    public void Cancel()
    {
        _generation++;
        try { _cts?.Cancel(); } catch { }
        _cts = null;
    }

    public void Close()
    {
        Cancel();
        _panel?.Close();
        _panel = null;
        State = null;
        if (_previous != IntPtr.Zero) Native.ForceForeground(_previous);
    }
}
