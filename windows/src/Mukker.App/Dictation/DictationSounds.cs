using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using NAudio.Wave;

namespace Mukker.App.Dictation;

internal enum DictationCue { Start, Stop, Paste }

/// <summary>
/// The three short cues (start, stop, paste), bundled as WPF resources and played with NAudio on the default
/// output device. Each player is kept in a list until it stops: <c>Play()</c> returns at once, so a local would be
/// collected (and the sound cut off) mid-cue.
/// </summary>
internal sealed class DictationSounds
{
    private readonly List<WaveOutEvent> _playing = new();

    public void Play(DictationCue cue, double volume)
    {
        try
        {
            var name = cue switch { DictationCue.Start => "dictation-start", DictationCue.Stop => "dictation-stop", _ => "dictation-paste" };
            var info = Application.GetResourceStream(new Uri($"pack://application:,,,/Mukker;component/Assets/Sounds/{name}.wav"));
            if (info?.Stream == null) return;
            var bytes = new MemoryStream();
            using (info.Stream) info.Stream.CopyTo(bytes);
            bytes.Position = 0;

            var reader = new WaveFileReader(bytes);
            var output = new WaveOutEvent { DeviceNumber = -1 /* WAVE_MAPPER: the default output */, Volume = (float)Math.Clamp(volume, 0, 1) };
            output.PlaybackStopped += (_, _) =>
            {
                _playing.Remove(output);
                output.Dispose();
                reader.Dispose();
            };
            output.Init(reader);
            _playing.Add(output);
            output.Play();
        }
        catch (Exception e) { AppHost.Log($"dictation: sound failed: {e.Message}"); }
    }
}
