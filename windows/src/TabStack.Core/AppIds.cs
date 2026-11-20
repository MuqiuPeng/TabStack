using System.Text.RegularExpressions;

namespace TabStack.Core;

/// <summary>App ids that survive updates. Many apps install each version into a folder named
/// after it (miHoYo / Hypergryph launchers: <c>…\1.20.1.392\HYP.exe</c>; Squirrel apps such as
/// Discord: <c>…\app-1.0.9\Discord.exe</c>), so the exe path changes with every update. The
/// version folder is replaced by <c>*</c>; tabs and per-app settings then keep matching.</summary>
public static partial class AppIds
{
    const char Sep = (char)92; // backslash
    [GeneratedRegex(@"^(app-)?v?\d+(\.\d+)+([-_+][0-9A-Za-z.]+)?$", RegexOptions.IgnoreCase)]
    private static partial Regex Version();

    /// <summary>Lower-cased exe path with version folders as <c>*</c>; AUMIDs and other ids unchanged.</summary>
    public static string FromExe(string exe)
    {
        if (!exe.Contains(Sep)) return exe;
        var parts = exe.ToLowerInvariant().Split(Sep);
        for (var i = 1; i < parts.Length - 1; i++)
            if (Version().IsMatch(parts[i])) parts[i] = "*";
        return string.Join(Sep, parts);
    }

    /// <summary>An exe that exists for this app now: <paramref name="exe"/> itself, else the same
    /// file in the newest version folder (the one an update left behind). Null when none.</summary>
    public static string? Locate(string? exe)
    {
        if (exe is null) return null;
        if (File.Exists(exe)) return exe;
        try
        {
            var parts = exe.Split(Sep);
            for (var i = parts.Length - 2; i >= 1; i--)
            {
                if (!Version().IsMatch(parts[i])) continue;
                var parent = string.Join(Sep, parts[..i]);
                var rest = string.Join(Sep, parts[(i + 1)..]);
                if (!Directory.Exists(parent)) return null;
                return Directory.EnumerateDirectories(parent)
                    .Where(d => Version().IsMatch(Path.GetFileName(d)))
                    .Select(d => Path.Combine(d, rest))
                    .Where(File.Exists)
                    .OrderByDescending(p => File.GetLastWriteTimeUtc(p))
                    .FirstOrDefault();
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return null;
    }
}
