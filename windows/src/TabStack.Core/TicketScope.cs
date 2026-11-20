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
            Words.Has(t.Title, name) || Words.Has(t.CustomName, name)
            || (t.Title?.Contains(projectPath, StringComparison.OrdinalIgnoreCase) ?? false));
    }
}
