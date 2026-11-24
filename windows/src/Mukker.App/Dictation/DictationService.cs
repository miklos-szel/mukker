using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using Mukker.App.Dictation.Engine;
using Mukker.App.Interop;
using Mukker.Core.Dictation;
using Mukker.Core.Settings;

namespace Mukker.App.Dictation;

public enum DictationPhase { Idle, Recording, Transcribing, Notice }

/// <summary>What the overlay and the tray show. <see cref="Message"/> is set only for <see cref="DictationPhase.Notice"/>.</summary>
public readonly record struct DictationState(DictationPhase Phase, string? Message = null)
{
    public static readonly DictationState Idle = new(DictationPhase.Idle);
}

/// <summary>
/// Dictation's coordinator: the trigger's presses become recording, the recording becomes text, and the text is
/// pasted into the app that was in front through <c>Paster.PasteText</c> — not suppressed, so it also stays on the
/// clipboard and lands in history like any other copy. Port of the Mac <c>DictationService</c>.
/// Everything here runs on the UI thread. Never logs the transcript: lengths and timings only.
/// </summary>
internal sealed class DictationService
{
    private static readonly TimeSpan NoticeDuration = TimeSpan.FromSeconds(2.5);

    private readonly AppHost _host;
    private readonly TranscriptionEngine _engine;
    private readonly DictationModelStore _store;
    private readonly DictationRecorder _recorder = new();
    private readonly DictationSounds _sounds = new();
    private readonly DispatcherTimer _noticeTimer = new() { Interval = NoticeDuration };
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private DictationPressMachine _machine;
    private DictationActivation _activation;
    private string _modelId;
    private DictationLanguage? _forcedLanguage;
    private DictationLanguage? _pendingLanguage;
    private IntPtr _target;
    private int _generation;

    public DictationState State { get; private set; } = DictationState.Idle;
    /// <summary>Microphone level, 0…1, while recording.</summary>
    public float Level { get; private set; }

    public event Action? StateChanged;
    public event Action<float>? LevelChanged;

    public bool IsRecording => State.Phase == DictationPhase.Recording;
    private DictationSettings Settings => _host.Settings.Current.Dictation;

    public DictationService(AppHost host, TranscriptionEngine engine, DictationModelStore store)
    {
        _host = host;
        _engine = engine;
        _store = store;
        _activation = Settings.Activation;
        _modelId = Settings.ModelId;
        _machine = new DictationPressMachine(_activation);
        _recorder.OnLevel = level =>
        {
            Level = level;
            LevelChanged?.Invoke(level);
        };
        _recorder.OnLimitReached = () =>
        {
            if (!IsRecording) return;
            AppHost.Log("dictation: recording reached the time limit");
            _machine.RecordingEnded();
            FinishRecording();
        };
        _noticeTimer.Tick += (_, _) =>
        {
            _noticeTimer.Stop();
            if (State.Phase == DictationPhase.Notice) SetState(DictationState.Idle);
        };
    }

    /// <summary>Re-reads the settings that need an action when they change (activation mode, model).</summary>
    public void SettingsChanged()
    {
        var s = Settings;
        if (s.Activation != _activation)
        {
            _activation = s.Activation;
            _machine = new DictationPressMachine(_activation);
        }
        // A different model frees the old one's memory now rather than at the idle timeout.
        if (s.ModelId != _modelId)
        {
            _modelId = s.ModelId;
            _engine.Unload();
        }
        if (!s.Enabled && IsRecording) CancelRecording("dictation switched off");
    }

    private double Now => _clock.Elapsed.TotalSeconds;

    // MARK: - Trigger

    /// <summary>Events from the key hook, already on the UI thread.</summary>
    public void HandleTriggerEvents(IReadOnlyList<TriggerEvent> events)
    {
        // [Interrupt(Base), Press(Language)]: a language shortcut pressed on top of the Ctrl+Win chord.
        // Cancel the chord's recording, return the machine to idle, then press the language trigger.
        if (events.Count == 2 && events[0].Kind == TriggerEventKind.Interrupt && events[1].Kind == TriggerEventKind.Press)
        {
            Apply(_machine.Interrupt());
            _machine.Reset();
            Press(events[1].Trigger.Language, events[1].Time);
            return;
        }
        foreach (var e in events)
        {
            switch (e.Kind)
            {
                case TriggerEventKind.Press: Press(e.Trigger.Language, e.Time); break;
                case TriggerEventKind.Release: Apply(_machine.Release(e.Time)); break;
                case TriggerEventKind.Interrupt: Apply(_machine.Interrupt()); break;
            }
        }
    }

    private void Press(DictationLanguage? language, double time)
    {
        _pendingLanguage = language;
        try { Apply(_machine.Press(time)); }
        finally { _pendingLanguage = null; }
    }

    /// <summary>Esc while recording (the key hook reports it; Esc still reaches the focused app).</summary>
    public void EscapePressed()
    {
        if (!IsRecording) return;
        _machine.RecordingEnded();
        CancelRecording("Esc");
    }

    /// <summary>The tray item: start when idle, stop when recording.</summary>
    public void ToggleFromMenu()
    {
        if (IsRecording)
        {
            _machine.RecordingEnded();
            FinishRecording();
        }
        else if (BeginRecording(fromMenu: true))
        {
            _machine.RecordingStartedElsewhere();
        }
    }

    private void Apply(DictationCommand? command)
    {
        switch (command)
        {
            case DictationCommand.Start:
                if (!BeginRecording(fromMenu: false)) _machine.RecordingEnded();
                break;
            case DictationCommand.Stop:
                FinishRecording();
                break;
            case DictationCommand.Cancel:
                CancelRecording("another key joined the trigger");
                break;
        }
    }

    // MARK: - Recording

    private bool BeginRecording(bool fromMenu)
    {
        var s = Settings;
        if (!s.Enabled || !TranscriptionEngine.IsSupported) return false;
        if (State.Phase is DictationPhase.Recording or DictationPhase.Transcribing) return false;

        var model = s.Model;
        if (!_store.IsInstalled(model))
        {
            ShowNotice($"Download {model.Name} in Settings → Dictation first.");
            _host.OpenSettings("dictation");
            return false;
        }
        if (DictationRecorder.IsMicrophoneBlocked())
        {
            ShowNotice(DictationRecorder.BlockedMessage);
            _host.OpenSettings("dictation");
            return false;
        }

        // The window to paste into: whatever has focus right now. From the tray menu that is the taskbar, which
        // is not a target; Deliver() then uses the foreground window of that moment instead.
        _target = fromMenu && IsShell(Native.GetForegroundWindow()) ? IntPtr.Zero : Native.GetForegroundWindow();

        _engine.Prewarm(model);
        try
        {
            _recorder.Start(s.MicrophoneId);
        }
        catch (Exception e)
        {
            AppHost.Log($"dictation: recording failed to start: {e.Message}");
            ShowNotice(e.Message);
            if (e.Message == DictationRecorder.BlockedMessage) _host.OpenSettings("dictation");
            return false;
        }

        _noticeTimer.Stop();
        Level = 0;
        _forcedLanguage = _pendingLanguage;
        SetState(new DictationState(DictationPhase.Recording));
        PlaySound(DictationCue.Start);
        AppHost.Log("dictation: recording started");
        return true;
    }

    private void FinishRecording()
    {
        if (!IsRecording) return;
        var samples = _recorder.Stop();
        var forced = _forcedLanguage;
        _forcedLanguage = null;
        PlaySound(DictationCue.Stop);
        var duration = samples.Length / DictationText.SampleRate;
        if (duration < DictationText.MinimumDuration)
        {
            AppHost.Log($"dictation: recording too short ({(int)(duration * 1000)} ms); dropped");
            SetState(DictationState.Idle);
            return;
        }

        SetState(new DictationState(DictationPhase.Transcribing));
        var token = ++_generation;
        var model = Settings.Model;
        var plan = DictationLanguagePlan.Plan(model, Settings.Language, Settings.PreferredLanguages, forced);
        var started = Stopwatch.StartNew();
        _engine.TranscribeAsync(samples, model, plan).ContinueWith(task =>
        {
            // The continuation is not on the UI thread.
            Application.Current.Dispatcher.BeginInvoke(() =>
            {
                if (token != _generation) return; // a newer recording or a cancel superseded this answer
                if (task.IsFaulted)
                {
                    var message = task.Exception?.GetBaseException().Message ?? "unknown error";
                    AppHost.Log($"dictation: transcription failed: {message}");
                    ShowNotice($"Couldn't transcribe: {message}");
                }
                else if (task.IsCanceled)
                {
                    SetState(DictationState.Idle);
                }
                else
                {
                    AppHost.Log($"dictation: transcribed {duration:0.0} s in {started.ElapsedMilliseconds} ms, language {task.Result.Language ?? "?"}, {task.Result.Text.Length} chars");
                    Deliver(task.Result.Text);
                }
            });
        }, System.Threading.Tasks.TaskScheduler.Default);
    }

    private void CancelRecording(string reason)
    {
        if (!IsRecording) return;
        _recorder.Cancel();
        _forcedLanguage = null;
        _generation++;
        SetState(DictationState.Idle);
        AppHost.Log($"dictation: recording cancelled: {reason}");
    }

    private void Deliver(string raw)
    {
        var text = DictationText.FinalText(raw, Settings.AppendTrailingSpace);
        if (text.Length == 0)
        {
            ShowNotice("Nothing heard.");
            return;
        }
        SetState(DictationState.Idle);
        var target = _target;
        if (target == IntPtr.Zero || !Native.IsWindow(target)) target = Native.GetForegroundWindow();
        _host.Paster.PasteText(text, target);
        PlaySound(DictationCue.Paste);
    }

    private static bool IsShell(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || Native.IsOwnWindow(hwnd)) return true;
        return Native.ClassNameOf(hwnd) is "Shell_TrayWnd" or "Shell_SecondaryTrayWnd" or "NotifyIconOverflowWindow" or "TopLevelWindowForOverflowXamlIsland" or "#32768";
    }

    // MARK: - Feedback

    /// <summary>A short note for the overlay (no model, nothing heard, an error). Clears itself after 2.5 s.</summary>
    public void ShowNotice(string message)
    {
        SetState(new DictationState(DictationPhase.Notice, message));
        _noticeTimer.Stop();
        _noticeTimer.Start();
    }

    private void SetState(DictationState state)
    {
        State = state;
        if (state.Phase != DictationPhase.Recording) Level = 0;
        StateChanged?.Invoke();
    }

    private void PlaySound(DictationCue cue)
    {
        if (Settings.SoundsEnabled) _sounds.Play(cue, Settings.SoundVolume);
    }
}
