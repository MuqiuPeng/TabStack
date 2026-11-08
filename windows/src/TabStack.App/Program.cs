using System.Diagnostics;
using System.Windows;
using TabStack.Core;
using TabStack.Platform.Windows;

namespace TabStack.App;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--watchdog" && int.TryParse(args[1], out var pid))
            return Watchdog(pid);
        if (args.Length >= 1 && args[0] == "--describe")
            return Describe(args.Skip(1));

        using var single = new Mutex(true, $@"Local\TabStack-{Environment.UserName}", out var first);
        if (!first) return 0;

        var platform = new WindowsPlatform();
        var ledger = new HiddenLedger(HiddenLedger.DefaultPath);
        // A previous run that died left windows hidden: bring them back before anything else.
        var restored = ledger.RestoreAll(platform);
        if (restored > 0) Log.Write($"crash recovery: showed {restored} hidden window(s)");
        StartWatchdog();

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var shell = new AppShell(platform, ledger);
        app.DispatcherUnhandledException += (_, e) =>
        {
            Log.Write("unhandled: " + e.Exception);
            shell.ShowAllHidden();
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            Log.Write("fatal: " + e.ExceptionObject);
            ledger.RestoreAll(platform);
        };
        app.Startup += (_, _) => shell.Start();
        app.Exit += (_, _) => shell.Stop();
        return app.Run();
    }

    /// <summary>A second copy of the exe that waits for this one to exit and shows whatever it
    /// left hidden. After a normal exit the ledger is empty and this does nothing.</summary>
    static void StartWatchdog()
    {
        try
        {
            Process.Start(new ProcessStartInfo(Environment.ProcessPath!, $"--watchdog {Environment.ProcessId}")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            });
        }
        catch (Exception e) { Log.Write("watchdog failed to start: " + e.Message); }
    }

    /// <summary>Diagnostics: prints how the platform sees the given window handles, or every
    /// taskbar window when none are given (redirect stdout to read it).</summary>
    static int Describe(IEnumerable<string> handles)
    {
        var p = new WindowsPlatform();
        var list = handles.Any()
            ? handles.Select(h => p.Describe(long.Parse(h))).ToList()
            : p.EnumerateWindows().Cast<WindowInfo?>().ToList();
        var output = new
        {
            monitors = p.Monitors(),
            windows = list.Select(w => new { window = w, placement = w is null ? null : p.GetPlacement(w.Hwnd) }),
        };
        Console.Out.WriteLine(System.Text.Json.JsonSerializer.Serialize(output, Store.Json));
        Console.Out.Flush();
        return 0;
    }

    static int Watchdog(int pid)
    {
        try
        {
            using var main = Process.GetProcessById(pid);
            main.WaitForExit();
        }
        catch (ArgumentException) { } // already gone
        var shown = HiddenLedger.RestoreFrom(HiddenLedger.DefaultPath, new WindowsPlatform());
        if (shown > 0) Log.Write($"watchdog: TabStack {pid} exited; showed {shown} hidden window(s)");
        return 0;
    }
}
