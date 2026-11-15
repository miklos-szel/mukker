namespace Mukker.Core;

/// <summary>
/// Where Mukker keeps its data. The folder name and database file name are frozen
/// (renaming them orphans user data), mirroring the macOS app's Branding constants.
/// </summary>
public sealed class AppPaths
{
    public const string SupportFolderName = "Mukker";
    public const string DatabaseFileName = "mukker.sqlite";

    public string DataDirectory { get; }
    public string SettingsDirectory { get; }

    public AppPaths(string dataDirectory, string settingsDirectory)
    {
        DataDirectory = dataDirectory;
        SettingsDirectory = settingsDirectory;
    }

    /// <summary>%LOCALAPPDATA%\Mukker for data, %APPDATA%\Mukker for settings.</summary>
    public static AppPaths Default()
    {
        var overrideDir = Environment.GetEnvironmentVariable("MUKKER_HOME");
        if (!string.IsNullOrEmpty(overrideDir))
            return new AppPaths(Path.Combine(overrideDir, "data"), Path.Combine(overrideDir, "settings"));
        return new AppPaths(
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), SupportFolderName),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), SupportFolderName));
    }

    public string DatabasePath => Path.Combine(DataDirectory, DatabaseFileName);
    public string ImagesDirectory => Path.Combine(DataDirectory, "images");
    public string RichTextDirectory => Path.Combine(DataDirectory, "richtext");
    public string SettingsPath => Path.Combine(SettingsDirectory, "settings.json");

    public static string DefaultForeverHistoryDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), SupportFolderName);

    public void EnsureDirectories()
    {
        Directory.CreateDirectory(DataDirectory);
        Directory.CreateDirectory(ImagesDirectory);
        Directory.CreateDirectory(RichTextDirectory);
        Directory.CreateDirectory(SettingsDirectory);
    }
}
