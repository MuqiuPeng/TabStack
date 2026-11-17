using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using TabStack.Core;

namespace TabStack.App;

/// <summary>The two pickers: Ctrl+Alt+F jumps to any workspace (Mac ⌃⌥F), Ctrl+Alt+A
/// adds a window or app to the current one (Mac ⌃⌥A).</summary>
sealed class Panels
{
    readonly AppShell shell;
    PickerWindow? open;
    List<(string name, string path)>? apps;

    public Panels(AppShell shell) => this.shell = shell;

    WorkspaceManager M => shell.Manager;

    MonitorInfo? FocusedDisplay => WorkspaceManager.Monitor(M.FocusedDisplay, shell.Platform.Monitors());

    /// <summary>The same key again closes the box; the other key swaps it.</summary>
    void Show(string kind, string placeholder, Func<string, IReadOnlyList<PickerItem>> source)
    {
        var was = open?.Tag as string;
        if (open is { IsLoaded: true }) open.Close();
        open = null;
        if (was == kind) return;
        open = new PickerWindow(placeholder, source, FocusedDisplay) { Tag = kind };
        open.Closed += (s, _) => { if (ReferenceEquals(open, s)) open = null; };
        open.Show();
    }

    // ───────────── Ctrl+Alt+F: workspaces ─────────────

    public void Search() => Show("search", "Go to workspace…", query =>
    {
        var rows = new List<PickerItem>();
        foreach (var ws in M.Search(query))
        {
            var where = ws.Id == M.Current.Id ? " (current)" : M.DisplayShowing(ws.Id) is not null ? " (other display)" : "";
            var tabs = string.Join(" · ", ws.Tabs.Take(4).Select(t => TitleLabels.Clean(t.DisplayName)));
            var id = ws.Id;
            rows.Add(new PickerItem(ws.Name + where, tabs.Length > 0 ? tabs : "No windows", null,
                () => M.SwitchWorkspace(id), Badge(ws)));
        }
        if (query.Length > 0 && !M.Workspaces.Any(w => string.Equals(w.Name, query, StringComparison.OrdinalIgnoreCase)))
            rows.Add(new PickerItem($"New Workspace “{query}”", "Create it and switch to it", null, () =>
            {
                var ws = M.CreateWorkspace(query);
                M.SwitchWorkspace(ws.Id);
            }, Plus()));
        return rows;
    });

    static FrameworkElement Badge(Workspace ws)
    {
        var color = (Color)ColorConverter.ConvertFromString(WorkspaceManager.Palette[(ws.Color ?? 0) % WorkspaceManager.Palette.Length]);
        return new Border
        {
            Width = 24, Height = 24, CornerRadius = new CornerRadius(6), Background = new SolidColorBrush(color),
            Child = new TextBlock
            {
                Text = ws.Name.Length > 0 ? ws.Name[..1].ToUpperInvariant() : "?", Foreground = Brushes.White, FontSize = 13,
                FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            },
        };
    }

    static FrameworkElement Plus() => new TextBlock
    {
        Text = "＋", Width = 24, FontSize = 18, TextAlignment = TextAlignment.Center,
        Foreground = new SolidColorBrush(Color.FromRgb(0xE6, 0xE6, 0xE6)),
    };

    // ───────────── Ctrl+Alt+A: add a window or app ─────────────

    public void QuickAdd()
    {
        var platform = shell.Platform;
        // The window in use when the key was pressed comes first, so the key then Enter adopts it.
        var fg = platform.ForegroundWindow();
        Show("add", "Add a window or app to " + M.Current.Name + "…", query =>
        {
            var here = M.Current.Tabs.Select(t => t.Hwnd).OfType<long>().ToHashSet();
            var visible = platform.EnumerateWindows().Where(w => w.Pid != Environment.ProcessId).ToList();
            var candidates = new List<(WindowInfo w, string? detail)>();
            if (visible.Find(w => w.Hwnd == fg) is { } front)
                candidates.Add((front, here.Contains(front.Hwnd) ? "Already in this workspace" : "The window you were using"));
            candidates.AddRange(visible.Where(w => w.Hwnd != fg && !here.Contains(w.Hwnd)).Select(w => (w, (string?)null)));
            // Windows other workspaces keep out of sight: adding one shares it (like Claude).
            foreach (var ws in M.Workspaces.Where(w => w.Id != M.Current.Id))
                foreach (var t in ws.Tabs)
                    if (t.Hwnd is { } h && !here.Contains(h) && candidates.All(c => c.w.Hwnd != h) && M.Live(h) is { } info)
                        candidates.Add((info, "In " + ws.Name));

            var rows = new List<PickerItem>();
            foreach (var (w, detail) in candidates)
            {
                if (!Matches(query, w.Title, w.AppName)) continue;
                var title = w.Title.Length > 0 ? TitleLabels.Clean(w.Title) : w.AppName;
                var info = w;
                rows.Add(new PickerItem(title, detail is null ? w.AppName : $"{w.AppName} · {detail}", IconCache.For(w.ExePath),
                    () => M.AddWindow(info)));
            }
            if (query.Length > 0)
                foreach (var (name, path) in Apps().Where(a => Matches(query, a.name)).Take(8))
                    rows.Add(new PickerItem("Open " + name, "Start it and add its window", IconCache.For(path), () => LaunchAndAdd(path)));
            return rows;
        });
    }

    static bool Matches(string query, params string[] texts) =>
        query.Length == 0 || texts.Any(t => t.Contains(query, StringComparison.CurrentCultureIgnoreCase));

    /// <summary>Start-menu shortcuts: apps that may not be running yet.</summary>
    List<(string name, string path)> Apps()
    {
        if (apps is not null) return apps;
        var roots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
            Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
        };
        var skip = new[] { "uninstall", "卸载", "readme", "help", "帮助", "license", "documentation", "website", "release notes" };
        apps = roots.Where(Directory.Exists)
            .SelectMany(r => SafeFiles(r))
            .Select(p => (name: Path.GetFileNameWithoutExtension(p), path: p))
            .Where(a => !skip.Any(s => a.name.Contains(s, StringComparison.OrdinalIgnoreCase)))
            .GroupBy(a => a.name, StringComparer.OrdinalIgnoreCase).Select(g => g.First())
            .OrderBy(a => a.name.Length).ToList();
        return apps;
    }

    static IEnumerable<string> SafeFiles(string root)
    {
        try { return Directory.EnumerateFiles(root, "*.lnk", SearchOption.AllDirectories).ToList(); }
        catch (Exception e) { Log.Write($"start menu {root}: {e.Message}"); return []; }
    }

    /// <summary>Starts an app and adds the first new window that comes to the front.</summary>
    void LaunchAndAdd(string path)
    {
        var platform = shell.Platform;
        var before = platform.EnumerateWindows().Select(w => w.Hwnd).ToHashSet();
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception e) { Log.Write($"launch {path}: {e.Message}"); return; }
        var deadline = DateTime.Now.AddSeconds(30);
        var poll = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        poll.Tick += (_, _) =>
        {
            var fg = platform.ForegroundWindow();
            if (!before.Contains(fg) && platform.EnumerateWindows().FirstOrDefault(w => w.Hwnd == fg) is { } w)
            {
                poll.Stop();
                M.AddWindow(w);
            }
            else if (DateTime.Now > deadline) poll.Stop();
        };
        poll.Start();
    }
}
