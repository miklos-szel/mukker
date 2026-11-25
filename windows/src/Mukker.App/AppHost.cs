using System;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using Mukker.App.Chime;
using Mukker.App.Capture;
using Mukker.App.Clipboard;
using Mukker.App.Dictation;
using Mukker.App.Dictation.Engine;
using Mukker.App.Editor;
using Mukker.App.Interop;
using Mukker.App.Popup;
using Mukker.App.Settings;
using Mukker.App.Snippets;
using Mukker.App.Translate;
using Mukker.App.Tray;
using Mukker.Core;
using Mukker.Core.Clipboard;
using Mukker.Core.Settings;
using Mukker.Core.Storage;

namespace Mukker.App;

/// <summary>
/// Owns every long-lived service and wires them together — start here to follow runtime flow.
/// The feature sets are independent at runtime; they share only settings, hotkeys, the tray and Settings.
/// </summary>
public sealed class AppHost : IDisposable
{
    public static AppHost Current { get; private set; } = null!;

    public AppPaths Paths { get; }
    public SettingsStore Settings { get; }
    public Database Database { get; }
    public ClipboardRepository Clips { get; }
    public SnippetRepository Snippets { get; }
    internal RetentionService Retention { get; }
    internal MessageWindow MessageWindow { get; }
    internal HotKeyManager HotKeys { get; }
    internal ClipboardMonitor Monitor { get; }
    internal Paster Paster { get; }
    internal FastAppendService FastAppend { get; }
    internal TrayController Tray { get; private set; } = null!;
    internal ChimeService Chime { get; }
    internal PopupController Popup { get; }
    internal TranslationController Translation { get; }
    internal CaptureCoordinator Capture { get; }
    internal TranscriptionEngine DictationEngine { get; }
    internal DictationModelStore DictationStore { get; }
    internal DictationService DictationSvc { get; }
    internal DictationKeyHook DictationHook { get; }
    private DictationOverlay? _dictationOverlay;

    private readonly DispatcherTimer _retentionTimer;
    private readonly DispatcherTimer _settingsDebounce;
    private SettingsWindow? _settingsWindow;
    private SnippetsManagerWindow? _snippetsWindow;

    public AppHost()
    {
        Current = this;
        Paths = AppPaths.Default();
        Paths.EnsureDirectories();
        Settings = new SettingsStore(Paths.SettingsPath);
        Database = new Database(Paths.DatabasePath);
        Clips = new ClipboardRepository(Database, Paths.DataDirectory);
        Snippets = new SnippetRepository(Database);
        Retention = new RetentionService(Clips, () => Settings.Current.Clipboard);

        MessageWindow = new MessageWindow();
        HotKeys = new HotKeyManager(MessageWindow);
        Monitor = new ClipboardMonitor(MessageWindow, Clips, Retention, Paths, () => Settings.Current.Clipboard);
        Paster = new Paster(Clips, Monitor, () => Settings.Current.Clipboard);
        FastAppend = new FastAppendService(Clips, Monitor, () => Settings.Current.Clipboard);
        Chime = new ChimeService(() => Settings.Current.Chime);
        Popup = new PopupController(this);
        Translation = new TranslationController(this);
        Capture = new CaptureCoordinator(this);
        DictationEngine = new TranscriptionEngine(Paths.ModelsDirectory, () => Settings.Current.Dictation);
        DictationStore = new DictationModelStore(Paths.ModelsDirectory, DictationEngine);
        DictationSvc = new DictationService(this, DictationEngine, DictationStore);
        DictationHook = new DictationKeyHook(() => Settings.Current.Dictation, () => HotKeys.Suspended,
            () => DictationSvc.IsRecording, DictationSvc.HandleTriggerEvents, DictationSvc.EscapePressed);

        _retentionTimer = new DispatcherTimer { Interval = TimeSpan.FromHours(1) };
        _retentionTimer.Tick += (_, _) => SweepRetention();
        _settingsDebounce = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _settingsDebounce.Tick += (_, _) =>
        {
            _settingsDebounce.Stop();
            SweepRetention();
        };
    }

    public void Start()
    {
        Tray = new TrayController(this);
        var s = Settings.Current.Shortcuts;
        HotKeys.Add(new("Clipboard popup", () => Settings.Current.Shortcuts.Popup, () => true, () => Popup.Toggle()));
        HotKeys.Add(new("Capture area", () => Settings.Current.Shortcuts.Area, () => true, () => Capture.CaptureArea()));
        HotKeys.Add(new("Capture fullscreen", () => Settings.Current.Shortcuts.Fullscreen, () => true, () => Capture.CaptureFullscreen()));
        HotKeys.Add(new("Scrolling capture", () => Settings.Current.Shortcuts.Scrolling, () => true, () => Capture.CaptureScrolling()));
        HotKeys.Add(new("Translate to English", () => Settings.Current.Shortcuts.TranslateEnglish,
            () => Settings.Current.Translation.Enabled, () => Translation.Request(Core.Translate.TranslationLanguage.English)));
        HotKeys.Add(new("Translate to Hungarian", () => Settings.Current.Shortcuts.TranslateHungarian,
            () => Settings.Current.Translation.Enabled, () => Translation.Request(Core.Translate.TranslationLanguage.Hungarian)));
        HotKeys.Add(new("Translate to German", () => Settings.Current.Shortcuts.TranslateGerman,
            () => Settings.Current.Translation.Enabled, () => Translation.Request(Core.Translate.TranslationLanguage.German)));
        HotKeys.ReRegister();

        Monitor.Start();
        FastAppend.Sync();
        _dictationOverlay = new DictationOverlay(DictationSvc, () => Settings.Current.Dictation.OverlayEnabled);
        DictationSvc.StateChanged += () => Tray.SetRecording(DictationSvc.IsRecording);
        HotKeys.SuspendedChanged += () => DictationHook.ResetTracker();
        DictationHook.Sync();
        Chime.Reschedule();
        _retentionTimer.Start();
        SweepRetention();
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, () =>
        {
            try { Clips.RemoveOrphanedSidecarFiles(); } catch (Exception e) { Log($"orphan sweep: {e.Message}"); }
        });

        Settings.Changed += (_, _) =>
        {
            HotKeys.ReRegister();
            FastAppend.Sync();
            DictationSvc.SettingsChanged();
            DictationHook.Sync();
            Chime.Reschedule();
            SyncStartup();
            _settingsDebounce.Stop();
            _settingsDebounce.Start();
        };
        SystemEvents.PowerModeChanged += (_, e) =>
        {
            if (e.Mode == PowerModes.Resume) Application.Current.Dispatcher.BeginInvoke(() => Chime.Reschedule());
        };
        SystemEvents.TimeChanged += (_, _) => Application.Current.Dispatcher.BeginInvoke(() => Chime.Reschedule());

        Log("started");
        RunDebugHook();
    }

    /// <summary>
    /// MUKKER_OPEN=popup|settings[:tab]|snippets|menu|menu-right|editor|translate-en|translate-hu|translate-de|
    /// dictation|dictation-notice|dictate-file:&lt;wav&gt; opens a surface at launch, so it can be screenshotted in a VM
    /// without a human clicking. <c>dictation</c> toggles a recording as the tray item does, <c>dictation-notice</c>
    /// shows a sample overlay notice, and <c>dictate-file</c> transcribes a WAV with the selected model and prints
    /// the result (the engine without a microphone).
    /// </summary>
    private void RunDebugHook()
    {
        var open = Environment.GetEnvironmentVariable("MUKKER_OPEN");
        if (string.IsNullOrEmpty(open)) return;
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, () =>
        {
            var parts = open.Split(':', 2);
            switch (parts[0])
            {
                case "popup": Popup.Show(); break;
                case "settings": OpenSettings(parts.Length > 1 ? parts[1] : null); break;
                case "snippets": OpenSnippetsManager(); break;
                case "menu": Tray.ShowActionsMenu(); break;
                case "menu-right": Tray.ShowSettingsMenu(); break;
                case "editor": EditorWindow.OpenSample(this); break;
                case "translate-en": Translation.Request(Core.Translate.TranslationLanguage.English); break;
                case "translate-hu": Translation.Request(Core.Translate.TranslationLanguage.Hungarian); break;
                case "translate-de": Translation.Request(Core.Translate.TranslationLanguage.German); break;
                case "dictation": DictationSvc.ToggleFromMenu(); break;
                case "dictation-notice": DictationSvc.ShowNotice("Download Whisper Large v3 Turbo in Settings → Dictation first."); break;
                case "dictate-file" when parts.Length > 1: DictateFileDebug.Run(parts[1], DictationEngine, Settings.Current.Dictation); break;
            }
        });
    }

    public void SweepRetention()
    {
        try
        {
            Retention.Sweep(DateTime.Now);
            Retention.Trim();
        }
        catch (Exception e) { Log($"retention: {e.Message}"); }
    }

    public void OpenSettings(string? tab = null)
    {
        if (_settingsWindow == null)
        {
            _settingsWindow = new SettingsWindow(this);
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        }
        _settingsWindow.SelectTab(tab);
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    public void OpenSnippetsManager()
    {
        if (_snippetsWindow == null)
        {
            _snippetsWindow = new SnippetsManagerWindow(this);
            _snippetsWindow.Closed += (_, _) => _snippetsWindow = null;
        }
        _snippetsWindow.Show();
        _snippetsWindow.Activate();
    }

    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    private void SyncStartup()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key == null) return;
            var exe = Environment.ProcessPath;
            if (Settings.Current.StartWithWindows && exe != null) key.SetValue("Mukker", $"\"{exe}\"");
            else if (key.GetValue("Mukker") != null) key.DeleteValue("Mukker", false);
        }
        catch (Exception e) { Log($"startup key: {e.Message}"); }
    }

    public void Quit()
    {
        Application.Current.Shutdown();
    }

    public void Dispose()
    {
        try { Monitor.Stop(); } catch { }
        FastAppend.Dispose();
        DictationHook.Dispose();
        _dictationOverlay?.Close();
        DictationEngine.Dispose();
        Tray?.Dispose();
        MessageWindow.Dispose();
        Database.Dispose();
    }

    private static readonly object LogLock = new();

    /// <summary>Appends a line to %LOCALAPPDATA%\Mukker\mukker.log. Never log clipboard or translated text.</summary>
    public static void Log(string message)
    {
        try
        {
            lock (LogLock)
            {
                var path = Path.Combine(AppPaths.Default().DataDirectory, "mukker.log");
                var info = new FileInfo(path);
                if (info.Exists && info.Length > 1_000_000) File.Delete(path);
                File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
            }
        }
        catch { /* logging must never throw */ }
    }
}
