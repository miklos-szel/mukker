using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Mukker.App.Dictation;
using Mukker.App.Dictation.Engine;
using Mukker.Core.Dictation;
using Mukker.Core.Settings;

namespace Mukker.App.Settings;

/// <summary>The Dictation tab. Same helpers as the other tabs; only the live parts (download rows, microphone test) are bespoke.</summary>
internal sealed partial class SettingsWindow
{
    private DictationRecorder? _micTest;

    private static string FormatSize(long bytes) =>
        bytes >= 1_000_000_000 ? $"{bytes / 1e9:0.00} GB" : bytes >= 100_000_000 ? $"{bytes / 1e6:0} MB" : $"{bytes / 1e6:0.0} MB";

    private UIElement BuildDictation()
    {
        var root = new StackPanel();
        var store = _host.DictationStore;

        if (!TranscriptionEngine.IsSupported)
        {
            root.Children.Add(new Border
            {
                BorderBrush = (Brush)FindResource("Danger"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6),
                Padding = new Thickness(10, 8, 10, 8), Margin = new Thickness(0, 0, 0, 10),
                Child = new TextBlock { Text = TranscriptionEngine.UnsupportedReason ?? "Dictation isn't available in this build.", TextWrapping = TextWrapping.Wrap, Foreground = (Brush)FindResource("Danger") },
            });
        }

        // MARK: Enable
        var g = Section(root, "Dictation");
        var body = new StackPanel();
        var enable = Toggle(g, "Enable dictation", s => s.Dictation.Enabled, (s, v) => s.Dictation.Enabled = v,
            "Hold the keys, speak, let go: what you said is pasted into the app in front. Speech is transcribed on this PC — audio never leaves it and is never written to disk. The text is also left on the clipboard and in the history.");
        enable.Click += (_, _) => body.IsEnabled = enable.IsChecked == true;
        body.IsEnabled = S.Dictation.Enabled;
        root.Children.Add(body);

        // MARK: Shortcut
        var sc = Section(body, "Shortcut");
        Grid? comboRow = null;
        var trigger = Choice(sc, "Key", Enum.GetValues<DictationTrigger>().Select(t => (t, t.Label())).ToArray(),
            s => s.Dictation.Trigger, (s, v) => s.Dictation.Trigger = v);
        comboRow = Row(sc, "Shortcut", new ShortcutRecorder(_host, () => S.Dictation.Combo, c => Save(s => s.Dictation.Combo = c)));
        void ShowCombo() => comboRow.Visibility = S.Dictation.Trigger == DictationTrigger.Combo ? Visibility.Visible : Visibility.Collapsed;
        trigger.SelectionChanged += (_, _) => Dispatcher.BeginInvoke(ShowCombo);
        ShowCombo();
        Choice(sc, "Activation", Enum.GetValues<DictationActivation>().Select(a => (a, a.Label())).ToArray(),
            s => s.Dictation.Activation, (s, v) => s.Dictation.Activation = v);
        Caption(sc, "A press combined with another key (Ctrl+Win+→, Ctrl+Win+D) is left alone. Esc cancels a recording.");

        // MARK: Language shortcuts
        var ls = Section(body, "Language shortcuts");
        var lsBody = new StackPanel();
        foreach (var l in Enum.GetValues<DictationLanguage>())
        {
            var lang = l;
            Row(lsBody, lang.Label(), new ShortcutRecorder(_host, () => S.Dictation.ComboFor(lang), c => Save(s =>
            {
                switch (lang)
                {
                    case DictationLanguage.English: s.Dictation.EnglishCombo = c; break;
                    case DictationLanguage.German: s.Dictation.GermanCombo = c; break;
                    default: s.Dictation.HungarianCombo = c; break;
                }
            })));
        }
        ls.Children.Add(lsBody);
        var lsNote = new TextBlock { Style = (Style)FindResource("Caption"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 6) };
        ls.Children.Add(lsNote);

        // MARK: Language
        var lg = Section(body, "Language");
        var langBody = new StackPanel();
        var picker = Choice(langBody, "Language", new (DictationLanguage? Value, string Text)[]
            {
                (null, "Automatic"), (DictationLanguage.English, "English"), (DictationLanguage.German, "German"), (DictationLanguage.Hungarian, "Hungarian"),
            }, s => s.Dictation.Language, (s, v) => s.Dictation.Language = v);
        var spoken = new StackPanel { Orientation = Orientation.Horizontal };
        var boxes = new Dictionary<DictationLanguage, CheckBox>();
        foreach (var l in Enum.GetValues<DictationLanguage>())
        {
            var lang = l;
            var cb = new CheckBox { Content = lang.Label(), IsChecked = S.Dictation.PreferredLanguages.Contains(lang), Margin = new Thickness(0, 0, 14, 0), VerticalAlignment = VerticalAlignment.Center };
            cb.Click += (_, _) =>
            {
                var set = Enum.GetValues<DictationLanguage>().Where(x => x == lang ? cb.IsChecked == true : S.Dictation.PreferredLanguages.Contains(x)).ToList();
                if (set.Count == 0) { cb.IsChecked = true; return; } // keep at least one: empty would silently mean "all three"
                Save(s => s.Dictation.PreferredLanguages = set);
            };
            boxes[lang] = cb;
            spoken.Children.Add(cb);
        }
        var spokenRow = Row(langBody, "Languages I speak", spoken);
        lg.Children.Add(langBody);
        var langNote = new TextBlock { Style = (Style)FindResource("Caption"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 6) };
        lg.Children.Add(langNote);

        void RefreshLanguage()
        {
            var model = S.Dictation.Model;
            var honours = model.HonoursLanguage;
            lsBody.IsEnabled = honours;
            langBody.IsEnabled = honours;
            spokenRow.IsEnabled = S.Dictation.Language == null;
            lsNote.Text = honours
                ? "A language shortcut starts dictation in that language, whatever the Language setting says; it works like the key above. \"Not set\" means off. Backspace clears one."
                : $"{model.Name} detects the language by itself, so per-language shortcuts need a Whisper model.";
            langNote.Text = honours
                ? "Automatic picks among the languages you speak for each recording."
                : $"{model.Name} detects the language by itself, so these settings only apply to the Whisper models.";
        }
        picker.SelectionChanged += (_, _) => Dispatcher.BeginInvoke(RefreshLanguage);

        // MARK: Microphone
        var mic = Section(body, "Microphone");
        var devices = DictationRecorder.ListDevices();
        var micItems = new List<(string Id, string Name)> { ("", "System default") };
        micItems.AddRange(devices.Select(d => (d.Id, d.Name)));
        if (!string.IsNullOrEmpty(S.Dictation.MicrophoneId) && devices.All(d => d.Id != S.Dictation.MicrophoneId))
            micItems.Add((S.Dictation.MicrophoneId, "Not connected"));
        var micChoice = Choice(mic, "Microphone", micItems.Select(i => (i.Id, i.Name)).ToArray(),
            s => s.Dictation.MicrophoneId, (s, v) => s.Dictation.MicrophoneId = v);
        micChoice.MinWidth = 280;

        var level = new ProgressBar { Minimum = 0, Maximum = 1, Width = 160, Height = 8, VerticalAlignment = VerticalAlignment.Center };
        var testButton = new Button { Content = "Start", Margin = new Thickness(10, 0, 0, 0), MinWidth = 60 };
        var testStatus = new TextBlock { Style = (Style)FindResource("Caption"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 4), Foreground = (Brush)FindResource("Danger") };
        void StopTest()
        {
            _micTest?.Cancel();
            _micTest = null;
            level.Value = 0;
            testButton.Content = "Start";
        }
        void StartTest()
        {
            testStatus.Text = "";
            var recorder = new DictationRecorder { OnLevel = l => level.Value = l };
            try
            {
                recorder.Start(S.Dictation.MicrophoneId);
                _micTest = recorder;
                testButton.Content = "Stop";
            }
            catch (Exception e) { testStatus.Text = e.Message; }
        }
        testButton.Click += (_, _) => { if (_micTest == null) StartTest(); else StopTest(); };
        micChoice.SelectionChanged += (_, _) => Dispatcher.BeginInvoke(() => { if (_micTest != null) { StopTest(); StartTest(); } });
        var testPanel = new StackPanel { Orientation = Orientation.Horizontal };
        testPanel.Children.Add(level);
        testPanel.Children.Add(testButton);
        Row(mic, "Test", testPanel);
        mic.Children.Add(testStatus);
        Caption(mic, "A microphone that isn't connected falls back to the system default.");

        var blocked = new StackPanel { Margin = new Thickness(0, 4, 0, 6) };
        blocked.Children.Add(new TextBlock { Text = DictationRecorder.BlockedMessage, TextWrapping = TextWrapping.Wrap, Foreground = (Brush)FindResource("Danger") });
        var privacy = new Button { Content = "Open Microphone Privacy Settings", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) };
        privacy.Click += (_, _) => Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });
        blocked.Children.Add(privacy);
        mic.Children.Add(blocked);
        void RefreshBlocked() => blocked.Visibility = DictationRecorder.IsMicrophoneBlocked() ? Visibility.Visible : Visibility.Collapsed;
        RefreshBlocked();
        Activated += (_, _) => RefreshBlocked(); // coming back from the Windows settings page

        // MARK: Model
        var md = Section(body, "Model");
        var rows = DictationCatalog.Models.Select(m => new ModelRow(this, m, store)).ToList();
        foreach (var r in rows) md.Children.Add(r.Root);
        Choice(md, "Unload from memory", Enum.GetValues<DictationUnloadDelay>().Select(d => (d, d.Label())).ToArray(),
            s => s.Dictation.UnloadDelay, (s, v) => s.Dictation.UnloadDelay = v);
        Caption(md, $"Models are downloaded once from Hugging Face, checked against a fixed checksum and kept in {store.FolderPath}. Keeping one loaded makes dictation start faster; it uses about as much memory as its size.");
        var folder = new Button { Content = "Open Models Folder", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 2, 0, 4) };
        folder.Click += (_, _) => Process.Start(new ProcessStartInfo("explorer.exe", $"\"{store.FolderPath}\"") { UseShellExecute = true });
        md.Children.Add(folder);

        // MARK: Feedback
        var fb = Section(body, "Feedback");
        Toggle(fb, "Show the recording indicator", s => s.Dictation.OverlayEnabled, (s, v) => s.Dictation.OverlayEnabled = v);
        var sounds = Toggle(fb, "Play sounds", s => s.Dictation.SoundsEnabled, (s, v) => s.Dictation.SoundsEnabled = v);
        var volume = SliderRow(fb, "Volume", 0, 1, 0.05, s => s.Dictation.SoundVolume, (s, v) => s.Dictation.SoundVolume = v, v => $"{v:P0}");
        void RefreshVolume() => volume.IsEnabled = sounds.IsChecked == true;
        sounds.Click += (_, _) => RefreshVolume();
        RefreshVolume();
        Toggle(fb, "Add a space after the text", s => s.Dictation.AppendTrailingSpace, (s, v) => s.Dictation.AppendTrailingSpace = v);

        // Live refresh: the model radio buttons and language enabling follow the saved settings, the rows follow the store.
        void OnSettings(object? _, EventArgs __) { RefreshLanguage(); foreach (var r in rows) r.Update(); }
        void OnStore() { foreach (var r in rows) r.Update(); }
        _host.Settings.Changed += OnSettings;
        store.Changed += OnStore;
        Closed += (_, _) =>
        {
            _host.Settings.Changed -= OnSettings;
            store.Changed -= OnStore;
            StopTest();
        };
        RefreshLanguage();
        foreach (var r in rows) r.Update();
        return root;
    }

    /// <summary>One model: select it, download it (with progress), or delete it. Built once, refreshed by <see cref="Update"/>.</summary>
    private sealed class ModelRow
    {
        private readonly SettingsWindow _w;
        private readonly DictationModel _model;
        private readonly DictationModelStore _store;
        private readonly RadioButton _radio;
        private readonly TextBlock _failure;
        private readonly Button _action = new() { MinWidth = 110, VerticalAlignment = VerticalAlignment.Center };
        private readonly ProgressBar _progress = new() { Minimum = 0, Maximum = 1, Width = 90, Height = 8, VerticalAlignment = VerticalAlignment.Center };
        private readonly Button _cancel = new() { Content = "Cancel", Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        private readonly TextBlock _verifying = new() { Text = "Verifying…", VerticalAlignment = VerticalAlignment.Center };
        private readonly StackPanel _trailing = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };

        public Grid Root { get; } = new() { Margin = new Thickness(0, 6, 0, 6) };

        public ModelRow(SettingsWindow window, DictationModel model, DictationModelStore store)
        {
            _w = window;
            _model = model;
            _store = store;
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            _radio = new RadioButton { GroupName = "dictationModel", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
            _radio.Click += (_, _) => _w.Save(s => s.Dictation.ModelId = model.Id);
            Grid.SetColumn(_radio, 0);
            Root.Children.Add(_radio);

            var info = new StackPanel();
            var title = new StackPanel { Orientation = Orientation.Horizontal };
            title.Children.Add(new TextBlock { Text = model.Name, FontWeight = FontWeights.Medium });
            if (model.Id == DictationCatalog.DefaultModelId)
                title.Children.Add(new TextBlock { Text = "Default", Style = (Style)Application.Current.FindResource("Caption"), Margin = new Thickness(6, 1, 0, 0), VerticalAlignment = VerticalAlignment.Center });
            info.Children.Add(title);
            info.Children.Add(new TextBlock { Text = $"{model.Summary} {FormatSize(model.File.ByteSize)}.", Style = (Style)Application.Current.FindResource("Caption"), TextWrapping = TextWrapping.Wrap });
            _failure = new TextBlock { Foreground = (Brush)Application.Current.FindResource("Danger"), FontSize = 11, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
            info.Children.Add(_failure);
            info.MouseLeftButtonUp += (_, _) => { _radio.IsChecked = true; _w.Save(s => s.Dictation.ModelId = model.Id); };
            Grid.SetColumn(info, 1);
            Root.Children.Add(info);

            _action.Click += (_, _) =>
            {
                if (_store.IsInstalled(_model)) _store.Delete(_model); else _store.Download(_model);
            };
            _cancel.Click += (_, _) => _store.Cancel(_model);
            Grid.SetColumn(_trailing, 2);
            Root.Children.Add(_trailing);
        }

        public void Update()
        {
            _radio.IsChecked = _w.S.Dictation.Model.Id == _model.Id;
            var phase = _store.PhaseOf(_model);
            _trailing.Children.Clear();
            _failure.Visibility = Visibility.Collapsed;
            switch (phase.Kind)
            {
                case ModelPhaseKind.Downloading:
                    _progress.Value = phase.Fraction;
                    _trailing.Children.Add(_progress);
                    _trailing.Children.Add(_cancel);
                    return;
                case ModelPhaseKind.Verifying:
                    _trailing.Children.Add(_verifying);
                    return;
                case ModelPhaseKind.Failed:
                    _failure.Text = phase.Message ?? "The download failed.";
                    _failure.Visibility = Visibility.Visible;
                    break;
            }
            _action.Content = _store.IsInstalled(_model) ? "Delete" : $"Download {FormatSize(_store.RemainingBytes(_model))}";
            _trailing.Children.Add(_action);
        }
    }
}
