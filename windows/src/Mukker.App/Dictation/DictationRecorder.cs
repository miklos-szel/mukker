using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using Mukker.Core.Dictation;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Mukker.App.Dictation;

/// <summary>A capture endpoint for the Settings picker.</summary>
internal sealed record MicrophoneDevice(string Id, string Name);

/// <summary>
/// Captures the microphone through WASAPI and turns it into 16 kHz mono Float32 <b>in memory</b> — audio is never
/// written to disk. WasapiCapture delivers the device's mix format (usually 32-bit float, 2 channels, 44.1/48 kHz),
/// which is downmixed and resampled as it arrives with an area-averaging (box) filter: each output sample is the mean
/// of the source samples it spans, which is also the anti-alias filter for the usual 48 kHz → 16 kHz step.
/// <para>The default input is the <i>console</i> default capture endpoint (what Windows' "Sound → Input" picks), not the
/// communications one, so Dictation follows the device the user chose for general use.</para>
/// Level and limit callbacks are marshalled to the UI dispatcher.
/// </summary>
internal sealed class DictationRecorder
{
    public static readonly int SampleRate = (int)DictationText.SampleRate;
    private static readonly int MaxSamples = (int)(DictationText.MaxDuration * DictationText.SampleRate);
    private const int E_ACCESSDENIED = unchecked((int)0x80070005);

    private readonly Dispatcher _dispatcher = Application.Current.Dispatcher;
    private readonly object _lock = new();
    private WasapiCapture? _capture;
    private float[] _samples = new float[SampleRate * 10];
    private int _count;
    private bool _limitReported;

    // Resampler / downmix state (capture thread only, guarded by _lock together with _samples).
    private WaveFormat? _format;
    private double _ratio;
    private double _acc, _accWeight;
    private int _levelStart;
    private long _lastLevelTicks;

    /// <summary>0…1 about 20 times a second while recording.</summary>
    public Action<float>? OnLevel { get; set; }
    /// <summary>The 5-minute cap was reached; the recorder has stopped taking samples.</summary>
    public Action? OnLimitReached { get; set; }

    public bool IsRecording => _capture != null;

    // MARK: - Devices and privacy

    /// <summary>Active capture endpoints.</summary>
    public static List<MicrophoneDevice> ListDevices()
    {
        var list = new List<MicrophoneDevice>();
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            foreach (var d in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            {
                using (d) list.Add(new MicrophoneDevice(d.ID, d.FriendlyName));
            }
        }
        catch (Exception e) { AppHost.Log($"dictation: listing microphones failed: {e.Message}"); }
        return list;
    }

    /// <summary>
    /// Windows' "Let desktop apps access your microphone" (or the master switch) is off. In that case WASAPI still
    /// opens the device and just delivers silence, so it has to be read from the consent store.
    /// </summary>
    public static bool IsMicrophoneBlocked()
    {
        const string path = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
        return Denied(Registry.CurrentUser, path)
            || Denied(Registry.CurrentUser, path + @"\NonPackaged")
            || Denied(Registry.LocalMachine, path);
    }

    private static bool Denied(RegistryKey hive, string path)
    {
        try
        {
            using var key = hive.OpenSubKey(path);
            return key?.GetValue("Value") is string v && v.Equals("Deny", StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    public const string BlockedMessage = "Windows is blocking microphone access. Allow desktop apps in Settings → Privacy → Microphone.";

    // MARK: - Recording

    /// <summary>Starts capturing from <paramref name="deviceId"/> (empty or not connected → the default input). Throws with a user-readable message.</summary>
    public void Start(string deviceId)
    {
        if (_capture != null) return;
        MMDevice? device = null;
        WasapiCapture? capture = null;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            if (!string.IsNullOrEmpty(deviceId))
            {
                try
                {
                    device = enumerator.GetDevice(deviceId);
                    if (device.State != DeviceState.Active) { device.Dispose(); device = null; }
                }
                catch { device = null; /* unplugged: fall back to the default */ }
            }
            device ??= enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);

            capture = new WasapiCapture(device);
            _format = capture.WaveFormat;
            lock (_lock)
            {
                _count = 0;
                _limitReported = false;
                _ratio = _format.SampleRate / (double)SampleRate;
                _acc = _accWeight = 0;
                _levelStart = 0;
                _lastLevelTicks = Environment.TickCount64;
            }
            capture.DataAvailable += OnData;
            capture.RecordingStopped += (_, _) => capture.Dispose();
            capture.StartRecording();
            _capture = capture;
        }
        catch (Exception e)
        {
            try { capture?.Dispose(); } catch { }
            throw new InvalidOperationException(Describe(e), e);
        }
        finally
        {
            device?.Dispose();
        }
    }

    private static string Describe(Exception e)
    {
        if (e is COMException com && com.HResult == E_ACCESSDENIED || e is UnauthorizedAccessException) return BlockedMessage;
        if (e is COMException { HResult: unchecked((int)0x80070490) } or ArgumentException) return "No microphone found.";
        return $"Couldn't start the microphone: {e.Message}";
    }

    /// <summary>Stops and returns everything captured as 16 kHz mono samples.</summary>
    public float[] Stop()
    {
        Halt();
        lock (_lock)
        {
            var result = new float[_count];
            Array.Copy(_samples, result, _count);
            _count = 0;
            return result;
        }
    }

    /// <summary>Stops and throws the audio away.</summary>
    public void Cancel()
    {
        Halt();
        lock (_lock) _count = 0;
    }

    private void Halt()
    {
        var capture = _capture;
        _capture = null;
        if (capture == null) return;
        capture.DataAvailable -= OnData;
        try { capture.StopRecording(); } catch { /* disposed on RecordingStopped */ }
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        var format = _format;
        if (format == null || e.BytesRecorded == 0) return;
        var channels = Math.Max(format.Channels, 1);
        var bytesPerSample = format.BitsPerSample / 8;
        if (bytesPerSample == 0) return;
        var frameBytes = bytesPerSample * channels;
        var frames = e.BytesRecorded / frameBytes;
        var isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat
            || (format is WaveFormatExtensible ext && ext.ToStandardWaveFormat().Encoding == WaveFormatEncoding.IeeeFloat);

        float? level = null;
        var limit = false;
        lock (_lock)
        {
            if (_capture == null) return; // stopped meanwhile
            var buffer = e.Buffer;
            for (var f = 0; f < frames; f++)
            {
                float sum = 0;
                var o = f * frameBytes;
                for (var c = 0; c < channels; c++)
                    sum += ReadSample(buffer, o + c * bytesPerSample, bytesPerSample, isFloat);
                Push(sum / channels);
                if (_count >= MaxSamples) { limit = !_limitReported; _limitReported = true; break; }
            }

            var now = Environment.TickCount64;
            if (now - _lastLevelTicks >= 50)
            {
                _lastLevelTicks = now;
                var n = _count - _levelStart;
                if (n > 0) level = DictationText.RmsLevel(_samples.AsSpan(_levelStart, n));
                _levelStart = _count;
            }
        }

        if (level is { } l && OnLevel is { } onLevel) _dispatcher.BeginInvoke(DispatcherPriority.Send, () => onLevel(l));
        if (limit && OnLimitReached is { } onLimit) _dispatcher.BeginInvoke(DispatcherPriority.Send, onLimit);
    }

    private static float ReadSample(byte[] b, int offset, int bytes, bool isFloat)
    {
        if (isFloat && bytes == 4) return BitConverter.ToSingle(b, offset);
        return bytes switch
        {
            2 => BitConverter.ToInt16(b, offset) / 32768f,
            3 => (((b[offset + 2] << 24) | (b[offset + 1] << 16) | (b[offset] << 8)) >> 8) / 8388608f,
            4 => BitConverter.ToInt32(b, offset) / 2147483648f,
            1 => (b[offset] - 128) / 128f,
            _ => 0f,
        };
    }

    /// <summary>One mono source sample into the area-averaging resampler. Caller holds the lock.</summary>
    private void Push(float sample)
    {
        if (_ratio <= 1)
        {
            // Source at or below 16 kHz (rare): nearest-neighbour hold, good enough for speech.
            var repeats = (int)Math.Round(1 / _ratio);
            for (var i = 0; i < Math.Max(repeats, 1); i++) Append(sample);
            return;
        }
        var remaining = 1.0;
        while (remaining > 1e-9)
        {
            var take = Math.Min(remaining, _ratio - _accWeight);
            _acc += sample * take;
            _accWeight += take;
            remaining -= take;
            if (_accWeight >= _ratio - 1e-9)
            {
                Append((float)(_acc / _ratio));
                _acc = _accWeight = 0;
            }
        }
    }

    private void Append(float value)
    {
        if (_count >= MaxSamples) return;
        if (_count == _samples.Length) Array.Resize(ref _samples, Math.Min(_samples.Length * 2, MaxSamples));
        _samples[_count++] = value;
    }
}
