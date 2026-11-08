using System.Text.Json.Serialization;

namespace TabStack.Core;

/// <summary>
/// One tab = one specific window of an app (one Chrome can back several tabs).
/// <see cref="Hwnd"/> is valid only while that window exists; when it is gone the tab is
/// <em>unbound</em> and re-binds the next time it is used: to a window of the same app with
/// the same title if there is one, otherwise to one no other tab is using.
/// </summary>
public sealed class AppTab
{
    public Guid Id { get; set; } = Guid.NewGuid();
    /// <summary>AUMID if the window has one, otherwise the full exe path in lower case.</summary>
    public string AppID { get; set; } = "";
    /// <summary>App name.</summary>
    public string Name { get; set; } = "";
    /// <summary>Name the user gave the tab, shown instead of the window title.</summary>
    public string? CustomName { get; set; }
    /// <summary>Last seen window title, for display and re-binding.</summary>
    public string? Title { get; set; }
    public Reopen? Reopen { get; set; }
    public Guid? PairedWith { get; set; }
    /// <summary>The window is also a tab in other workspaces.</summary>
    public bool? Shared { get; set; }

    // Windows additions
    /// <summary>Runtime window handle (Mac windowID).</summary>
    public long? Hwnd { get; set; }
    /// <summary>Executable of the app, for its icon while the tab is unbound.</summary>
    public string? ExePath { get; set; }
    /// <summary>Window class, used for re-binding.</summary>
    public string? ClassName { get; set; }
    public Placement? Placement { get; set; }
    public bool? NoSleep { get; set; }

    [JsonIgnore]
    public string DisplayName =>
        !string.IsNullOrEmpty(CustomName) ? CustomName! :
        !string.IsNullOrEmpty(Title) ? Title! : Name;
}

/// <summary>How to bring a window back when its handle no longer exists.</summary>
public sealed class Reopen
{
    /// <summary>Project folder of an editor window (VS Code and forks).</summary>
    public string? Folder { get; set; }
    /// <summary>Every tab of a browser window, in order.</summary>
    public List<string>? Urls { get; set; }
    /// <summary>File shown by a document window.</summary>
    public string? Document { get; set; }

    [JsonIgnore]
    public bool IsEmpty => Folder is null && (Urls is null || Urls.Count == 0) && Document is null;
}

public enum PlacementState
{
    Normal,
    Maximized,
    Minimized,
    Snapped,
}

public readonly record struct Rect(int X, int Y, int W, int H);

/// <summary>Where a window was and how it was shown when its workspace was left.</summary>
public sealed class Placement
{
    public PlacementState State { get; set; }
    /// <summary>Restored-size rectangle, in screen coordinates.</summary>
    public Rect NormalRect { get; set; }
    /// <summary>Actual rectangle (authoritative when snapped).</summary>
    public Rect ActualRect { get; set; }
    /// <summary>Monitor device path.</summary>
    public string? Monitor { get; set; }
    public int Dpi { get; set; }
    /// <summary>Shown (not minimized, not hidden by us) when the workspace was left.</summary>
    public bool Visible { get; set; }
}

public enum SleepLevel
{
    Awake,
    Throttled,
    Closed,
}

public sealed class SleepState
{
    public SleepLevel Level { get; set; }
    public double Since { get; set; }
}

/// <summary>A saved set of windows. Switching workspaces hides the previous set and brings
/// back the one selected last in the new one.</summary>
public sealed class Workspace
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public List<AppTab> Tabs { get; set; } = new();
    public Guid? LastTabID { get; set; }
    /// <summary>Index into the colour palette.</summary>
    public int? Color { get; set; }
    /// <summary>Always among the workspaces the sidebar shows.</summary>
    public bool? Pinned { get; set; }
    /// <summary>When it was used (seconds since 1970), newest last; feeds the frecency ranking.</summary>
    public List<double>? Usage { get; set; }

    // Windows additions
    /// <summary>Stacking order (top first) of the visible tabs when the workspace was left.</summary>
    public List<Guid>? ZOrder { get; set; }
    public Guid? ForegroundTab { get; set; }
    public SleepState? Sleep { get; set; }
    public bool? NoSleep { get; set; }
    /// <summary>Tiling mode (as on the Mac): a selected tab fills the work area beside the
    /// sidebar, a pair splits it. Otherwise windows keep their own placement.</summary>
    public bool? Tiled { get; set; }

    public AppTab? Tab(Guid id) => Tabs.Find(t => t.Id == id);
}

/// <summary>Everything saved to disk.</summary>
public sealed class AppState
{
    public List<Workspace> Workspaces { get; set; } = new();
    public Guid? CurrentWorkspace { get; set; }
    /// <summary>How many workspaces the sidebar shows (the rest are reached by search).</summary>
    public int? ActiveWorkspaceLimit { get; set; }
    public Settings Settings { get; set; } = new();
    /// <summary>The display whose sidebar was used last; it shows <see cref="CurrentWorkspace"/>.</summary>
    public string? FocusedDisplay { get; set; }
    /// <summary>The workspace every other display with a sidebar shows, by monitor id.</summary>
    public Dictionary<string, Guid>? OtherDisplays { get; set; }
    /// <summary>What displays showed before they were unplugged, so they get it back.</summary>
    public Dictionary<string, Guid>? RememberedDisplays { get; set; }
}

public sealed class Settings
{
    /// <summary>Apps whose windows are minimized instead of hidden when their workspace is left
    /// (apps that close or misbehave when hidden), by appID.</summary>
    public List<string> MinimizeApps { get; set; } = new();
    /// <summary>Hotkey overrides: action id → chord such as "Ctrl+Alt+Left"; "" disables.</summary>
    public Dictionary<string, string> HotKeys { get; set; } = new();
    /// <summary>New workspaces start in tiling mode.</summary>
    public bool TileNewWorkspaces { get; set; }
    /// <summary>Monitors (by id) that get no sidebar and show no workspace of their own;
    /// windows there belong to whichever workspace they are tabs of.</summary>
    public List<string> NoSidebarMonitors { get; set; } = new();
}
