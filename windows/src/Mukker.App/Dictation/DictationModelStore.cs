using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Mukker.App.Dictation.Engine;
using Mukker.Core.Dictation;

namespace Mukker.App.Dictation;

public enum ModelPhaseKind { Idle, Downloading, Verifying, Failed }

/// <summary>Where a model's download is. <see cref="Fraction"/> is 0…1 over every file the model still needs.</summary>
public readonly record struct ModelPhase(ModelPhaseKind Kind, double Fraction = 0, string? Message = null)
{
    public static readonly ModelPhase Idle = new(ModelPhaseKind.Idle);
}

/// <summary>
/// Downloads, verifies and deletes the Dictation model files under the models folder. A file only lands under its
/// final name after its SHA-256 matched, so "the file exists" means "the file is good". Port of the Mac store:
/// streamed to <c>&lt;file&gt;.partial</c>, hashed off the UI thread, renamed into place.
/// State lives on the UI thread; <see cref="Changed"/> fires there (progress at most ~10 times a second).
/// </summary>
internal sealed class DictationModelStore
{
    private static readonly HttpClient Http = new(new HttpClientHandler { AllowAutoRedirect = true }) { Timeout = Timeout.InfiniteTimeSpan };

    private readonly string _directory;
    private readonly TranscriptionEngine _engine;
    private readonly Dispatcher _dispatcher = Application.Current.Dispatcher;
    private readonly Dictionary<string, ModelPhase> _phases = new();
    private readonly Dictionary<string, CancellationTokenSource> _running = new();

    public event Action? Changed;

    public DictationModelStore(string modelsDirectory, TranscriptionEngine engine)
    {
        _directory = modelsDirectory;
        _engine = engine;
        System.IO.Directory.CreateDirectory(_directory);
        // A .partial is a download that never finished (crash, quit); it is never resumed.
        try
        {
            foreach (var f in System.IO.Directory.EnumerateFiles(_directory, "*.partial")) { try { File.Delete(f); } catch { } }
        }
        catch { /* folder unreadable: nothing to clean */ }
    }

    public string FolderPath => _directory;
    public string PathOf(DictationModelFile file) => System.IO.Path.Combine(_directory, file.FileName);
    public bool IsPresent(DictationModelFile file) => File.Exists(PathOf(file));
    public bool IsInstalled(DictationModel model) => DictationStorePlan.IsInstalled(model, IsPresent);
    public long RemainingBytes(DictationModel model) => DictationStorePlan.RemainingBytes(model, IsPresent);
    public ModelPhase PhaseOf(DictationModel model) => _phases.TryGetValue(model.Id, out var p) ? p : ModelPhase.Idle;

    // MARK: - Download

    public void Download(DictationModel model)
    {
        if (_running.ContainsKey(model.Id)) return;
        var missing = DictationStorePlan.MissingFiles(model, IsPresent);
        if (missing.Count == 0) return;
        var total = DictationStorePlan.RemainingBytes(model, IsPresent);
        var cts = new CancellationTokenSource();
        _running[model.Id] = cts;
        SetPhase(model, new(ModelPhaseKind.Downloading, 0));
        AppHost.Log($"dictation: downloading {model.Id}: {missing.Count} file(s), {total} bytes");
        _ = Task.Run(() => RunAsync(model, missing, total, cts));
    }

    public void Cancel(DictationModel model)
    {
        if (_running.Remove(model.Id, out var cts)) cts.Cancel();
        SetPhase(model, ModelPhase.Idle);
    }

    /// <summary>
    /// Removes the model's own file, plus the shared detector when no other installed model needs it. The engine
    /// memory-maps loaded models and Windows won't delete a mapped file, so the engine is unloaded first (that is
    /// posted to its worker thread) and each delete is retried for up to ~2 s off the UI thread.
    /// </summary>
    public void Delete(DictationModel model)
    {
        Cancel(model);
        var files = DictationStorePlan.FilesToDelete(model, IsPresent);
        _engine.Unload();
        _ = Task.Run(async () =>
        {
            foreach (var file in files)
            {
                var path = PathOf(file);
                for (var attempt = 0; ; attempt++)
                {
                    try { File.Delete(path); break; }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                    {
                        if (attempt >= 10)
                        {
                            AppHost.Log($"dictation: couldn't delete {file.FileName}: {e.Message}");
                            var message = $"Couldn't delete {file.FileName}: {e.Message}";
                            _dispatcher.BeginInvoke(() => SetPhase(model, new(ModelPhaseKind.Failed, 0, message)));
                            break;
                        }
                        await Task.Delay(200).ConfigureAwait(false);
                    }
                }
            }
            AppHost.Log($"dictation: deleted {model.Id}");
            _dispatcher.BeginInvoke(() => Changed?.Invoke());
        });
    }

    private async Task RunAsync(DictationModel model, IReadOnlyList<DictationModelFile> files, long total, CancellationTokenSource cts)
    {
        var token = cts.Token;
        long done = 0;
        long lastPost = 0;
        string? partial = null;
        try
        {
            foreach (var file in files)
            {
                partial = PathOf(file) + ".partial";
                using (var response = await Http.GetAsync(file.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false))
                {
                    if (!response.IsSuccessStatusCode)
                        throw new DownloadFailure($"The server answered {(int)response.StatusCode}.");
                    await using var source = await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
                    await using var target = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true);
                    var buffer = new byte[1 << 17];
                    long received = 0;
                    int n;
                    while ((n = await source.ReadAsync(buffer, token).ConfigureAwait(false)) > 0)
                    {
                        await target.WriteAsync(buffer.AsMemory(0, n), token).ConfigureAwait(false);
                        received += n;
                        var now = Environment.TickCount64;
                        if (now - lastPost >= 100)
                        {
                            lastPost = now;
                            var fraction = Math.Min((done + received) / (double)Math.Max(total, 1), 1);
                            Post(model, cts, () => SetPhase(model, new(ModelPhaseKind.Downloading, fraction)));
                        }
                    }
                }

                Post(model, cts, () => SetPhase(model, new(ModelPhaseKind.Verifying)));
                var actual = DictationText.Sha256OfFile(partial); // we are already off the UI thread
                token.ThrowIfCancellationRequested();
                if (actual != file.Sha256)
                    throw new DownloadFailure("The downloaded file didn't match its checksum.");
                File.Move(partial, PathOf(file), overwrite: true);
                partial = null;
                done += file.ByteSize;
                var f = Math.Min(done / (double)Math.Max(total, 1), 1);
                Post(model, cts, () => { SetPhase(model, new(ModelPhaseKind.Downloading, f)); Changed?.Invoke(); });
            }
            Post(model, cts, () =>
            {
                _running.Remove(model.Id);
                SetPhase(model, ModelPhase.Idle);
                AppHost.Log($"dictation: {model.Id} ready");
            });
        }
        catch (OperationCanceledException)
        {
            DeletePartial(partial);
        }
        catch (Exception e)
        {
            DeletePartial(partial);
            var message = e is DownloadFailure ? e.Message : e is IOException ? $"Couldn't save the file: {e.Message}" : e.Message;
            AppHost.Log($"dictation: download of {model.Id} failed: {message}");
            Post(model, cts, () =>
            {
                _running.Remove(model.Id);
                SetPhase(model, new(ModelPhaseKind.Failed, 0, message));
            });
        }
    }

    private static void DeletePartial(string? path)
    {
        if (path == null) return;
        try { File.Delete(path); } catch { }
    }

    /// <summary>Runs on the UI thread, and only while <paramref name="cts"/> is still this model's download (a cancel makes late updates stale).</summary>
    private void Post(DictationModel model, CancellationTokenSource cts, Action action) =>
        _dispatcher.BeginInvoke(DispatcherPriority.Normal, () =>
        {
            if (_running.TryGetValue(model.Id, out var current) && current == cts) action();
        });

    private void SetPhase(DictationModel model, ModelPhase phase)
    {
        if (phase.Kind == ModelPhaseKind.Idle) _phases.Remove(model.Id);
        else _phases[model.Id] = phase;
        Changed?.Invoke();
    }

    private sealed class DownloadFailure(string message) : Exception(message);
}
