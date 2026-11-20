using System.Diagnostics;
using System.IO;
using TabStack.Core;

namespace TabStack.App;

/// <summary>Starts the app of a tab. Packaged apps (Claude, Store apps) start through their
/// AUMID: their exe lives in a versioned WindowsApps folder that can't be run directly and
/// moves with every update. A single-instance app that is already running (closed to the
/// tray) shows its own window when started again.</summary>
static class Launcher
{
    public static bool Start(AppTab tab)
    {
        var target = tab.AppID.Contains('!') ? @"shell:AppsFolder\" + tab.AppID
            : AppIds.Locate(tab.ExePath);
        if (target is null) return false;
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
            Log.Write($"launch {target}");
            return true;
        }
        catch (Exception e) { Log.Write($"launch {target}: {e.Message}"); return false; }
    }
}
