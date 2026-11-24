using System;
using System.IO;
using System.Threading.Tasks;
using Mukker.Core.Dictation;
using Mukker.Core.Settings;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Mukker.App.Dictation.Engine;

/// <summary>
/// MUKKER_OPEN=dictate-file:&lt;wav&gt; — the engine without a microphone, the counterpart of the Mac's
/// MUKKER_DICTATE_FILE. This is the ONLY place a transcript is written anywhere: to <c>dictate-file.txt</c>
/// next to the audio file. The log gets only the language and the length.
/// </summary>
internal static class DictateFileDebug
{
    public static void Run(string wavPath, TranscriptionEngine engine, DictationSettings settings)
    {
        _ = RunAsync(wavPath, engine, settings);   // never block the UI thread on a model load
    }

    private static async Task RunAsync(string wavPath, TranscriptionEngine engine, DictationSettings settings)
    {
        string output = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(wavPath)) ?? ".", "dictate-file.txt");
        try
        {
            float[] samples = await Task.Run(() => ReadMono16k(wavPath));
            var model = settings.Model;
            var plan = DictationLanguagePlan.Plan(model, settings.Language, settings.PreferredLanguages);
            var result = await engine.TranscribeAsync(samples, model, plan);
            WriteOutput(output, result.Text);
            AppHost.Log($"dictation: dictate-file [{result.Language ?? "?"}] {result.Text.Length} chars");
        }
        catch (Exception ex)
        {
            WriteOutput(output, "error: " + ex.Message);
            AppHost.Log($"dictation: dictate-file failed: {ex.Message}");
        }
    }

    private static void WriteOutput(string path, string line)
    {
        try { File.WriteAllText(path, line + Environment.NewLine); }
        catch (Exception ex) { AppHost.Log($"dictation: dictate-file could not write its output: {ex.Message}"); }
    }

    /// <summary>Any PCM/float WAV (any rate, any channel count) as 16 kHz mono float.</summary>
    internal static float[] ReadMono16k(string path)
    {
        using var reader = new WaveFileReader(path);
        ISampleProvider src = reader.ToSampleProvider();   // PCM 8/16/24/32 or IEEE float -> float
        if (src.WaveFormat.Channels > 1)
        {
            // Average every channel into one.
            src = new ChannelAverager(src);
        }
        if (src.WaveFormat.SampleRate != 16000) src = new WdlResamplingSampleProvider(src, 16000);

        var all = new System.Collections.Generic.List<float>();
        var buffer = new float[16000];
        int n;
        while ((n = src.Read(buffer, 0, buffer.Length)) > 0)
            for (int i = 0; i < n; i++) all.Add(buffer[i]);
        return all.ToArray();
    }

    /// <summary>Downmixes N interleaved channels to mono by averaging.</summary>
    private sealed class ChannelAverager : ISampleProvider
    {
        private readonly ISampleProvider _src;
        private readonly int _channels;
        private float[] _tmp = Array.Empty<float>();
        public ChannelAverager(ISampleProvider src)
        {
            _src = src;
            _channels = src.WaveFormat.Channels;
            WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(src.WaveFormat.SampleRate, 1);
        }
        public WaveFormat WaveFormat { get; }
        public int Read(float[] buffer, int offset, int count)
        {
            int need = count * _channels;
            if (_tmp.Length < need) _tmp = new float[need];
            int read = _src.Read(_tmp, 0, need) / _channels;
            for (int i = 0; i < read; i++)
            {
                float sum = 0;
                for (int c = 0; c < _channels; c++) sum += _tmp[i * _channels + c];
                buffer[offset + i] = sum / _channels;
            }
            return read;
        }
    }
}
