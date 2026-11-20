using Microsoft.Win32;
using TabStack.Core;

namespace TabStack.App;

/// <summary>Start TabStack at sign-in (HKCU\…\Run). Written from the running exe each start,
/// so the entry follows the exe if it moves.</summary>
static class Autostart
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "TabStack";

    public static void Apply(bool on)
    {
        try
        {
            using var run = Registry.CurrentUser.CreateSubKey(Key);
            if (on)
            {
                var value = $"\"{Environment.ProcessPath}\"";
                if (run.GetValue(Name) as string != value) run.SetValue(Name, value);
            }
            else if (run.GetValue(Name) is not null) run.DeleteValue(Name);
        }
        catch (Exception e) { Log.Write("autostart: " + e.Message); }
    }
}
