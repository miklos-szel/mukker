using System.Text.Json;
using System.Text.Json.Serialization;

namespace Mukker.Core.Settings;

/// <summary>
/// Loads and saves <see cref="AppSettings"/> as JSON. Callers mutate <see cref="Current"/>
/// and call <see cref="Save"/>; <see cref="Changed"/> fires after every save so services can re-read.
/// </summary>
public sealed class SettingsStore
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
        PropertyNameCaseInsensitive = true,
    };

    private readonly string _path;
    private readonly object _lock = new();

    public AppSettings Current { get; private set; }
    public event EventHandler? Changed;

    public SettingsStore(string path)
    {
        _path = path;
        Current = Load(path);
    }

    public static AppSettings Load(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                var json = File.ReadAllText(path);
                return JsonSerializer.Deserialize<AppSettings>(json, JsonOptions) ?? new AppSettings();
            }
        }
        catch (Exception)
        {
            // A corrupt file falls back to defaults rather than crashing; keep the bad copy for inspection.
            try { File.Copy(path, path + ".bad", overwrite: true); } catch { /* ignore */ }
        }
        return new AppSettings();
    }

    public void Save()
    {
        lock (_lock)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(Current, JsonOptions));
            File.Move(tmp, _path, overwrite: true);
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Update(Action<AppSettings> mutate)
    {
        mutate(Current);
        Save();
    }
}
