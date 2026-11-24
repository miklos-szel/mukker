using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Mukker.Core.Dictation;
using Mukker.Core.Settings;

namespace Mukker.App.Dictation.Engine;

internal sealed record TranscriptionResult(string Text, string? Language);

/// <summary>
/// Loads a speech model, keeps it warm, runs it and unloads it after the configured idle delay — the
/// counterpart of the Mac's TranscriptionEngine. Everything native happens on ONE dedicated worker thread
/// (a session is single-threaded and a model allows one run at a time); the returned tasks complete off the
/// UI thread, so callers marshal. Never logs the transcript — only lengths, timings and the language.
/// </summary>
internal sealed class TranscriptionEngine : IDisposable
{
    private readonly string _modelsDirectory;
    private readonly Func<DictationSettings> _settings;
    private readonly BlockingCollection<Action> _queue = new();
    private readonly Thread _worker;
    private readonly Loaded _loaded;
    private readonly object _timerLock = new();
    private Timer? _unloadTimer;
    private int _generation;     // bumped whenever a pending unload is cancelled
    private bool _disposed;

    public TranscriptionEngine(string modelsDirectory, Func<DictationSettings> settings)
    {
        _modelsDirectory = modelsDirectory;
        _settings = settings;
        _loaded = new Loaded(modelsDirectory);
        _worker = new Thread(WorkerLoop) { IsBackground = true, Name = "Mukker.Transcription" };
        _worker.Start();
    }

    /// <summary>x64 process and transcribe.dll loaded with the matching version (lazy, cached).</summary>
    public static bool IsSupported => TranscribeNative.IsSupported;

    /// <summary>A user-facing sentence when <see cref="IsSupported"/> is false.</summary>
    public static string? UnsupportedReason => TranscribeNative.UnsupportedReason;

    /// <summary>Loads <paramref name="model"/> in the background if it is installed, so the load overlaps
    /// with the user speaking. Cancels a pending unload.</summary>
    public void Prewarm(DictationModel model)
    {
        if (!IsSupported) return;
        CancelUnload();
        if (!File.Exists(PathOf(model.File))) return;
        Enqueue(() =>
        {
            try { _loaded.Ensure(model); }
            catch (Exception ex) { AppHost.Log($"dictation: prewarm failed: {ex.Message}"); }
        });
        ScheduleUnload(skipImmediate: true);   // a prewarm that is never followed by a run still lets go
    }

    /// <param name="samples">16 kHz mono float PCM.</param>
    public Task<TranscriptionResult> TranscribeAsync(float[] samples, DictationModel model, DictationLanguagePlan plan)
    {
        if (!IsSupported)
            return Task.FromException<TranscriptionResult>(new InvalidOperationException(UnsupportedReason ?? "Dictation is not available."));
        foreach (var file in DictationCatalog.Files(model))
        {
            if (file == DictationCatalog.LanguageDetector && plan is not DictationLanguagePlan.Detect) continue;
            if (!File.Exists(PathOf(file)))
                return Task.FromException<TranscriptionResult>(new FileNotFoundException($"{model.Name} isn't downloaded yet."));
        }

        CancelUnload();
        var tcs = new TaskCompletionSource<TranscriptionResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        Enqueue(() =>
        {
            TranscriptionResult? result = null;
            Exception? error = null;
            try { result = _loaded.Run(samples, model, plan); }
            catch (Exception ex) { error = ex; AppHost.Log($"dictation: transcription failed: {ex.Message}"); }
            ScheduleUnload(skipImmediate: false);
            if (error is not null) tcs.SetException(error); else tcs.SetResult(result!);
        });
        return tcs.Task;
    }

    /// <summary>Drops the loaded model and detector (model switched or deleted, or the idle delay).</summary>
    public void Unload()
    {
        CancelUnload();
        Enqueue(_loaded.Unload);
    }

    public void Dispose()
    {
        lock (_timerLock)
        {
            if (_disposed) return;
            _disposed = true;
            _unloadTimer?.Dispose();
            _unloadTimer = null;
            _generation++;
        }
        try { _queue.CompleteAdding(); } catch (ObjectDisposedException) { }
        if (!_worker.Join(TimeSpan.FromSeconds(10))) AppHost.Log("dictation: engine worker did not stop in time");
        else _queue.Dispose();
    }

    // ---- internals -------------------------------------------------------------------------------------

    private string PathOf(DictationModelFile f) => Path.Combine(_modelsDirectory, f.FileName);

    private void Enqueue(Action work)
    {
        try { _queue.Add(work); }
        catch (InvalidOperationException) { /* disposed or completed (ObjectDisposedException derives from it): nothing to do */ }
    }

    private void WorkerLoop()
    {
        try
        {
            foreach (var work in _queue.GetConsumingEnumerable())
            {
                try { work(); }
                catch (Exception ex) { AppHost.Log($"dictation: worker: {ex.Message}"); }
            }
        }
        finally
        {
            try { _loaded.Unload(); } catch { }
        }
    }

    private void CancelUnload()
    {
        lock (_timerLock)
        {
            _generation++;
            _unloadTimer?.Dispose();
            _unloadTimer = null;
        }
    }

    private void ScheduleUnload(bool skipImmediate)
    {
        DictationUnloadDelay delay;
        try { delay = _settings().UnloadDelay; } catch { delay = DictationUnloadDelay.FiveMinutes; }
        if (delay == DictationUnloadDelay.Never) return;
        if (delay == DictationUnloadDelay.Immediately)
        {
            if (!skipImmediate) Unload();
            return;
        }
        lock (_timerLock)
        {
            if (_disposed) return;
            _unloadTimer?.Dispose();
            int gen = ++_generation;
            _unloadTimer = new Timer(_ =>
            {
                // Runs on the worker; a newer request (which bumps the generation) wins over a stale timer.
                Enqueue(() => { if (Volatile.Read(ref _generation) == gen) _loaded.Unload(); });
            }, null, TimeSpan.FromSeconds((int)delay), Timeout.InfiniteTimeSpan);
        }
    }

    /// <summary>The native objects, confined to the worker thread.</summary>
    private sealed class Loaded
    {
        private readonly string _dir;
        private string? _modelId;
        private IntPtr _model, _session, _detectorModel, _detectorSession;
        private bool _forceCpu;   // sticky after a backend failure

        public Loaded(string dir) => _dir = dir;

        private string PathOf(DictationModelFile f) => Path.Combine(_dir, f.FileName);

        public void Ensure(DictationModel model)
        {
            if (_modelId == model.Id && _session != IntPtr.Zero) return;
            Unload();
            var sw = Stopwatch.StartNew();
            string backend = Load(PathOf(model.File), out _model, out _session, detector: false);
            if (model.NeedsLanguageDetector)
            {
                try { Load(PathOf(DictationCatalog.LanguageDetector), out _detectorModel, out _detectorSession, detector: true); }
                catch (Exception ex)
                {
                    // Without the detector Automatic falls back to the first preferred language.
                    AppHost.Log($"dictation: language detector unavailable: {ex.Message}");
                }
            }
            _modelId = model.Id;
            AppHost.Log($"dictation: loaded {model.Id} on {backend} in {sw.ElapsedMilliseconds} ms");
        }

        /// <summary>Loads a model and its session. AUTO may land on Vulkan; when that fails with a backend
        /// error (no usable GPU, e.g. in a VM) the load is retried on the CPU.</summary>
        private string Load(string path, out IntPtr model, out IntPtr session, bool detector)
        {
            int request = _forceCpu ? TranscribeNative.BackendCpu : TranscribeNative.BackendAuto;
            while (true)
            {
                IntPtr m = IntPtr.Zero;
                try
                {
                    m = TranscribeNative.LoadModel(path, request, out string backend);
                    session = detector ? TranscribeNative.CreateLangIdSession(m) : TranscribeNative.CreateSession(m);
                    model = m;
                    return backend;
                }
                catch (TranscribeException ex) when (ex.Status == TranscribeNative.ErrBackend && request != TranscribeNative.BackendCpu)
                {
                    TranscribeNative.FreeModel(m);
                    AppHost.Log("dictation: backend failed, retrying on the CPU");
                    request = TranscribeNative.BackendCpu;
                    _forceCpu = true;
                }
                catch
                {
                    TranscribeNative.FreeModel(m);
                    throw;
                }
            }
        }

        public TranscriptionResult Run(float[] samples, DictationModel model, DictationLanguagePlan plan)
        {
            Ensure(model);
            string? hint = null;
            switch (plan)
            {
                case DictationLanguagePlan.ModelDecides:
                    break;
                case DictationLanguagePlan.Fixed f:
                    hint = f.Language.Code();
                    break;
                case DictationLanguagePlan.Detect d:
                    // Too short to score (under 0.5 s) or any other detector hiccup: fall back to the
                    // most-preferred language rather than failing.
                    if (_detectorSession != IntPtr.Zero)
                    {
                        try { hint = TranscribeNative.DetectLanguage(_detectorSession, samples, d.Among.Select(l => l.Code()).ToArray()); }
                        catch (Exception ex) { AppHost.Log($"dictation: language detection skipped: {ex.Message}"); }
                    }
                    hint ??= d.Among.Count > 0 ? d.Among[0].Code() : null;
                    break;
            }

            var sw = Stopwatch.StartNew();
            (string Text, string? Language) r;
            try { r = TranscribeNative.Run(_session, samples, hint); }
            catch (TranscribeException ex) when (ex.Status == TranscribeNative.ErrBackend && !_forceCpu)
            {
                // Recoverable per the header: reload on the CPU and run once more.
                AppHost.Log("dictation: backend failed during the run, reloading on the CPU");
                _forceCpu = true;
                Unload();
                Ensure(model);
                r = TranscribeNative.Run(_session, samples, hint);
            }
            string? language = r.Language ?? hint;
            AppHost.Log($"dictation: transcribed {samples.Length / 16} ms of audio in {sw.ElapsedMilliseconds} ms, {r.Text.Length} chars, language {language ?? "?"}");
            return new TranscriptionResult(r.Text, language);
        }

        public void Unload()
        {
            if (_modelId is not null) AppHost.Log($"dictation: unloaded {_modelId}");
            // Sessions first, then the models they borrow.
            TranscribeNative.FreeSession(_session);
            TranscribeNative.FreeLangIdSession(_detectorSession);
            TranscribeNative.FreeModel(_model);
            TranscribeNative.FreeModel(_detectorModel);
            _session = _detectorSession = _model = _detectorModel = IntPtr.Zero;
            _modelId = null;
        }
    }
}
