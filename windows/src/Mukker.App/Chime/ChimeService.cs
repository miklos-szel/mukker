using System;
using System.IO;
using System.Linq;
using System.Media;
using System.Windows.Threading;
using Mukker.Core.Chime;
using Mukker.Core.Settings;

namespace Mukker.App.Chime;

/// <summary>
/// Plays a sound at the top of every hour within the active range. Re-armed on an absolute deadline after
/// every fire, clock change and resume — never a repeating one-hour timer, which drifts with sleep.
/// </summary>
internal sealed class ChimeService
{
    public const string MediaFolder = @"C:\Windows\Media";
    private readonly Func<ChimeSettings> _settings;
    private readonly DispatcherTimer _timer = new();
    private SoundPlayer? _player; // retained: playback is async

    public ChimeService(Func<ChimeSettings> settings)
    {
        _settings = settings;
        _timer.Tick += (_, _) =>
        {
            _timer.Stop();
            var s = _settings();
            if (s.HourlyChime && ChimeSchedule.IsActive(DateTime.Now.Hour, s.HourlyChimeStartHour, s.HourlyChimeEndHour)) Play();
            Reschedule();
        };
    }

    public void Reschedule()
    {
        _timer.Stop();
        if (!_settings().HourlyChime) return;
        var debugEveryMinute = Environment.GetEnvironmentVariable("MUKKER_CHIME_EVERY_MINUTE") == "1";
        var now = DateTime.Now;
        var next = debugEveryMinute
            ? new DateTime(now.Year, now.Month, now.Day, now.Hour, now.Minute, 1).AddMinutes(now.Second >= 1 ? 1 : 0)
            : ChimeSchedule.NextFire(now);
        _timer.Interval = next - now;
        _timer.Start();
    }

    public static string[] AvailableSounds()
    {
        try
        {
            return Directory.GetFiles(MediaFolder, "*.wav").Select(System.IO.Path.GetFileNameWithoutExtension).OfType<string>()
                .OrderBy(n => n, StringComparer.CurrentCultureIgnoreCase).ToArray();
        }
        catch { return Array.Empty<string>(); }
    }

    public void Play(string? name = null)
    {
        name ??= _settings().HourlyChimeSound;
        var path = System.IO.Path.Combine(MediaFolder, name + ".wav");
        if (!File.Exists(path)) path = System.IO.Path.Combine(MediaFolder, "Windows Notify System Generic.wav");
        if (!File.Exists(path)) { SystemSounds.Asterisk.Play(); return; }
        try
        {
            _player?.Dispose();
            _player = new SoundPlayer(path);
            _player.Play();
        }
        catch { SystemSounds.Asterisk.Play(); }
    }
}
