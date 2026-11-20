namespace TabStack.Core;

/// <summary>Which TicketDeck projects a workspace is about (⌃⌥T shows their tickets). The Mac
/// version reads the folders its editors and terminals have open; Windows windows don't say
/// that, so this goes by names: a project belongs to a workspace named like its folder, or
/// whose window titles name the folder (VS Code "file - TabStack - Visual Studio Code",
/// Explorer "TabStack", a terminal showing "E:\projects\TabStack").</summary>
public static class TicketScope
{
    public static bool Holds(Workspace ws, string projectPath)
    {
        var name = Path.GetFileName(projectPath.TrimEnd('\\', '/'));
        if (name.Length == 0) return false;
        if (string.Equals(ws.Name.Trim(), name, StringComparison.OrdinalIgnoreCase)) return true;
        return ws.Tabs.Any(t =>
            Names(t.Title, name) || Names(t.CustomName, name)
            || (t.Title?.Contains(projectPath, StringComparison.OrdinalIgnoreCase) ?? false));
    }

    /// <summary>Whether <paramref name="text"/> has <paramref name="name"/> as a word of its own
    /// (so "TabStack" is not found in "TabStackOverflow").</summary>
    static bool Names(string? text, string name)
    {
        if (string.IsNullOrEmpty(text)) return false;
        for (var i = text.IndexOf(name, StringComparison.OrdinalIgnoreCase); i >= 0;
             i = text.IndexOf(name, i + 1, StringComparison.OrdinalIgnoreCase))
        {
            var before = i == 0 || !char.IsLetterOrDigit(text[i - 1]);
            var end = i + name.Length;
            var after = end == text.Length || !char.IsLetterOrDigit(text[end]);
            if (before && after) return true;
        }
        return false;
    }
}
