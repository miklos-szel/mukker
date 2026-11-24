using Mukker.Core.Settings;

namespace Mukker.Core.Dictation;

public enum DictationCommand { Start, Stop, Cancel }

/// <summary>
/// Turns trigger press/release/interrupt events into start/stop/cancel for the activation mode.
/// Exact port of the Mac's <c>DictationPressMachine</c>; times are seconds on any monotonic clock.
/// </summary>
public sealed class DictationPressMachine
{
    public enum Phase
    {
        Idle,
        /// <summary>Key down, recording since <see cref="DictationPressMachine.HoldingSince"/>.</summary>
        Holding,
        /// <summary>Key up, still recording (a tap in hold-or-toggle, or toggle mode).</summary>
        Latched,
        /// <summary>Key down; this press stopped the recording. Waiting for release.</summary>
        Stopping,
        /// <summary>Key down; the press was cancelled (another key joined it).</summary>
        Suppressed,
    }

    public const double DefaultThreshold = 0.3;

    public DictationActivation Activation { get; set; }
    public double Threshold { get; set; }
    public Phase State { get; private set; } = Phase.Idle;
    /// <summary>When the current hold began; meaningful only in <see cref="Phase.Holding"/>.</summary>
    public double HoldingSince { get; private set; }

    public DictationPressMachine(DictationActivation activation, double threshold = DefaultThreshold)
    {
        Activation = activation;
        Threshold = threshold;
    }

    public DictationCommand? Press(double time)
    {
        switch (State)
        {
            case Phase.Idle:
                State = Phase.Holding;
                HoldingSince = time;
                return DictationCommand.Start;
            case Phase.Latched:
                State = Phase.Stopping;
                return DictationCommand.Stop;
            default:
                return null; // key repeat
        }
    }

    public DictationCommand? Release(double time)
    {
        switch (State)
        {
            case Phase.Holding:
                switch (Activation)
                {
                    case DictationActivation.PushToTalk:
                        State = Phase.Idle;
                        return DictationCommand.Stop;
                    case DictationActivation.Toggle:
                        State = Phase.Latched;
                        return null;
                    default:
                        if (time - HoldingSince >= Threshold)
                        {
                            State = Phase.Idle;
                            return DictationCommand.Stop;
                        }
                        State = Phase.Latched;
                        return null;
                }
            case Phase.Stopping:
            case Phase.Suppressed:
                State = Phase.Idle;
                return null;
            default:
                return null;
        }
    }

    /// <summary>Another key went down while the trigger was held — that press was a shortcut, not dictation.</summary>
    public DictationCommand? Interrupt()
    {
        if (State != Phase.Holding) return null;
        State = Phase.Suppressed;
        return DictationCommand.Cancel;
    }

    /// <summary>Recording was started without the key (the menu): the next press stops it.</summary>
    public void RecordingStartedElsewhere()
    {
        if (State == Phase.Idle) State = Phase.Latched;
    }

    /// <summary>The recording ended some other way (Esc, the menu, the time limit).</summary>
    public void RecordingEnded()
    {
        if (State == Phase.Holding) State = Phase.Suppressed;
        else if (State == Phase.Latched) State = Phase.Idle;
    }

    /// <summary>Back to idle, e.g. between the chord's cancel and a language trigger's press.</summary>
    public void Reset() => State = Phase.Idle;
}
