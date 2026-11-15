using System;
using System.Threading;
using System.Windows;

namespace Mukker.App;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        // One instance per user session: a second launch just exits.
        using var mutex = new Mutex(true, @"Local\Mukker.SingleInstance", out var isFirst);
        if (!isFirst) return 0;

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Resources.MergedDictionaries.Add(new ResourceDictionary
        {
            Source = new Uri("pack://application:,,,/Mukker;component/Theme.xaml", UriKind.Absolute),
        });
        AppHost? host = null;
        app.Startup += (_, _) =>
        {
            host = new AppHost();
            host.Start();
        };
        app.Exit += (_, _) => host?.Dispose();
        app.DispatcherUnhandledException += (_, e) =>
        {
            AppHost.Log($"unhandled: {e.Exception}");
            e.Handled = true; // a menu-bar utility should not vanish on one bad event
        };
        return app.Run();
    }
}
