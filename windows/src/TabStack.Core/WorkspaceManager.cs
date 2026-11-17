namespace TabStack.Core;

/// <summary>
/// The workspace state machine: which workspace is shown, which tab is selected, which window
/// each tab is bound to. Not thread-safe: call it from the UI thread.
/// </summary>
public sealed class WorkspaceManager
{
    public static readonly string[] Palette =
        ["#4F7DF3", "#E5534B", "#3FB950", "#D29922", "#A371F7", "#DB61A2", "#39C5CF", "#8B949E"];

    readonly IWindowPlatform platform;
    readonly Store store;
    readonly HiddenLedger ledger;
    readonly Func<double> clock;
    AppState state;
    double lastDwell;

    /// <summary>Raised after anything the sidebar shows has changed.</summary>
    public event Action? Changed;
    /// <summary>Something the user should be told about.</summary>
    public event Action<string>? Notice;
    /// <summary>Windows we put away (when, which app), to notice apps that close when hidden.</summary>
    readonly Dictionary<long, (double at, string appID)> hiddenAt = new();

    public WorkspaceManager(IWindowPlatform platform, Store store, HiddenLedger ledger, Func<double>? clock = null)
    {
        this.platform = platform;
        this.store = store;
        this.ledger = ledger;
        this.clock = clock ?? Frecency.Now;
        state = store.Load();
        if (state.Workspaces.Count == 0)
            state.Workspaces.Add(new Workspace { Name = "Default", Color = 0 });
        if (state.CurrentWorkspace is not { } cur || state.Workspaces.All(w => w.Id != cur))
            state.CurrentWorkspace = state.Workspaces[0].Id;
        ValidateBindings();
        AssignDisplays(apply: false);
        if (Current.Usage is null) Frecency.RecordUse(Current, this.clock());
        lastDwell = this.clock();
        RecomputeActive();
    }

    public IReadOnlyList<Workspace> Workspaces => state.Workspaces;
    public Workspace Current => state.Workspaces.First(w => w.Id == state.CurrentWorkspace);
    public HashSet<Guid> ActiveIDs { get; private set; } = new();
    public IEnumerable<Workspace> ActiveWorkspaces => state.Workspaces.Where(w => ActiveIDs.Contains(w.Id));

    public int ActiveLimit
    {
        get => state.ActiveWorkspaceLimit is int n and > 0 ? n : Frecency.DefaultLimit;
        set { state.ActiveWorkspaceLimit = value; RecomputeActive(); Save(); Changed?.Invoke(); }
    }

    public Workspace? Find(Guid id) => state.Workspaces.Find(w => w.Id == id);

    public void Save() => store.Save(state);

    public void RecomputeActive() =>
        ActiveIDs = Frecency.Active(state.Workspaces, Current.Id, Others.Values, ActiveLimit, clock());

    // ───────────────────────── Displays ─────────────────────────
    // As on the Mac: every display with a sidebar shows a workspace of its own. The display
    // whose sidebar (or window) was used last is "focused" and shows Current; hotkeys and
    // menus act on it.

    Dictionary<string, Guid> Others => state.OtherDisplays ??= new();

    /// <summary>The monitors that get a sidebar (never none while any monitor exists).</summary>
    public IReadOnlyList<MonitorInfo> SidebarMonitors() => SidebarMonitors(platform.Monitors());

    IReadOnlyList<MonitorInfo> SidebarMonitors(IReadOnlyList<MonitorInfo> all)
    {
        var list = all.Where(m => !state.Settings.NoSidebarMonitors.Contains(m.Device)).ToList();
        if (list.Count == 0 && all.Count > 0) list.Add(all.FirstOrDefault(m => m.Primary) ?? all[0]);
        return list;
    }

    public string? FocusedDisplay => state.FocusedDisplay;

    /// <summary>The workspace a display shows (null: more displays than workspaces).</summary>
    public Workspace? WorkspaceOn(string device) =>
        device == state.FocusedDisplay ? Current : Others.TryGetValue(device, out var id) ? Find(id) : null;

    /// <summary>The other display showing a workspace, if any.</summary>
    public string? DisplayShowing(Guid id) => Others.FirstOrDefault(kv => kv.Value == id).Key;

    /// <summary>Workspaces on screen: the current one first, then the other displays'.</summary>
    public IEnumerable<Workspace> Displayed =>
        new[] { Current }.Concat(Others.Values.Select(Find).OfType<Workspace>());

    static HashSet<long> WindowsOf(IEnumerable<Workspace> workspaces) =>
        workspaces.SelectMany(w => w.Tabs).Where(t => t.Hwnd is not null).Select(t => t.Hwnd!.Value).ToHashSet();

    public static MonitorInfo? Monitor(string? device, IReadOnlyList<MonitorInfo> monitors) =>
        monitors.FirstOrDefault(m => m.Device == device);

    MonitorInfo? DisplayOf(Workspace ws, IReadOnlyList<MonitorInfo> monitors) =>
        Monitor(ws.Id == Current.Id ? state.FocusedDisplay : DisplayShowing(ws.Id), monitors);

    /// <summary>Makes another display's sidebar the one hotkeys and menus act on.</summary>
    public bool FocusDisplay(string device)
    {
        if (device == state.FocusedDisplay || !Others.TryGetValue(device, out var id) || Find(id) is not { } ws) return false;
        Others.Remove(device);
        if (state.FocusedDisplay is { } f) Others[f] = Current.Id;
        state.FocusedDisplay = device;
        state.CurrentWorkspace = ws.Id;
        RecomputeActive();
        Save();
        Changed?.Invoke();
        return true;
    }

    /// <summary>
    /// Gives every display with a sidebar a workspace of its own (no two show the same one):
    /// the one it showed before if still free, else the most used free one. With
    /// <paramref name="apply"/>, workspaces whose display went away are put away and ones that
    /// just got a display are brought back on it. Call after displays come or go, after the
    /// sidebar monitors setting changes and after workspaces are deleted.
    /// </summary>
    public void AssignDisplays(bool apply = true)
    {
        var monitors = platform.Monitors();
        var displays = SidebarMonitors(monitors);
        if (displays.Count == 0) return;
        var remembered = state.RememberedDisplays ??= new();
        foreach (var (d, id) in Others) remembered[d] = id;
        if (state.FocusedDisplay is { } fd) remembered[fd] = Current.Id;

        var connected = displays.Select(m => m.Device).ToList();
        if (state.FocusedDisplay is not { } focused || !connected.Contains(focused))
            state.FocusedDisplay = (displays.FirstOrDefault(m => m.Primary) ?? displays[0]).Device;

        var used = new HashSet<Guid> { Current.Id };
        var next = new Dictionary<string, Guid>();
        foreach (var d in connected.Where(d => d != state.FocusedDisplay))
        {
            if ((Others.TryGetValue(d, out var id) || remembered.TryGetValue(d, out id)) && Find(id) is not null && !used.Contains(id))
                next[d] = id;
            else if (Search("").FirstOrDefault(w => !used.Contains(w.Id)) is { } ws)
                next[d] = ws.Id;
            else continue; // fewer workspaces than displays: this one shows nothing
            used.Add(next[d]);
        }
        var before = new Dictionary<string, Guid>(Others);
        state.OtherDisplays = next;
        if (apply)
        {
            var keep = WindowsOf(Displayed);
            foreach (var id in before.Values.Except(next.Values).Where(id => id != Current.Id))
            {
                if (Find(id) is not { } gone) continue;
                Capture(gone);
                PutAwayAll(gone, keep);
            }
            foreach (var (d, id) in next)
            {
                if (before.TryGetValue(d, out var was) && was == id) continue;
                if (Find(id) is not { } ws) continue;
                var windows = ws.Tabs.Select(Resolve).OfType<WindowInfo>().Select(w => w.Hwnd).ToHashSet();
                BringBack(ws, windows, Monitor(d, monitors), activate: false);
            }
        }
        RecomputeActive();
        if (!apply) return;
        Save();
        Changed?.Invoke();
    }

    void PutAwayAll(Workspace ws, HashSet<long> keep)
    {
        foreach (var t in ws.Tabs)
        {
            if (t.Hwnd is not { } h || keep.Contains(h)) continue;
            // Locked: we can't hide it. Closed by its app: already out of sight, and taking it
            // into the ledger would have it shown (unresponsive) when the workspace comes back.
            if (Live(h) is not { } info || info.Locked) continue;
            PutAway(h, info.AppID);
        }
    }

    public List<Workspace> Search(string query) => Frecency.Search(state.Workspaces, query, clock());

    // ───────────────────────── Binding ─────────────────────────

    /// <summary>Drop handles that no longer name the same app's window (after a restart).</summary>
    void ValidateBindings()
    {
        var boot = platform.BootTime();
        var rebooted = state.BootTime is { } saved && Math.Abs(saved - boot) > 120;
        state.BootTime = boot;
        if (rebooted)
        {
            foreach (var t in state.Workspaces.SelectMany(w => w.Tabs)) t.Hwnd = null;
            RebindByTitle();
            return;
        }
        foreach (var t in state.Workspaces.SelectMany(w => w.Tabs))
        {
            if (t.Hwnd is { } h && platform.Describe(h)?.AppID != t.AppID)
                t.Hwnd = null;
        }
    }

    /// <summary>After a reboot: give every tab the window with exactly its title first, so a
    /// tab is not handed another tab's window just because it was looked at earlier. The
    /// rest bind as they are needed (<see cref="Resolve"/>).</summary>
    void RebindByTitle()
    {
        var windows = platform.EnumerateWindows().ToList();
        var held = new HashSet<long>();
        var byWindow = new Dictionary<long, AppTab>();
        foreach (var t in state.Workspaces.SelectMany(w => w.Tabs))
        {
            if (string.IsNullOrEmpty(t.Title)) continue;
            var pick = windows.Find(w => w.AppID == t.AppID && w.Title == t.Title
                && (!held.Contains(w.Hwnd) || (t.Shared == true && byWindow[w.Hwnd].Shared == true)));
            if (pick is null) continue;
            Bind(t, pick);
            held.Add(pick.Hwnd);
            byWindow.TryAdd(pick.Hwnd, t);
        }
    }

    /// <summary>The live window of a tab, re-binding it if its window is gone: same app and
    /// title first, else a window of the app no other tab holds.</summary>
    public WindowInfo? Resolve(AppTab tab)
    {
        if (tab.Hwnd is { } h)
        {
            if (platform.Describe(h) is { } info && info.AppID == tab.AppID && Open(info)) return info;
            tab.Hwnd = null;
        }
        var held = state.Workspaces.SelectMany(w => w.Tabs)
            .Where(t => t.Id != tab.Id && t.Hwnd is not null && t.Shared != true)
            .Select(t => t.Hwnd!.Value).ToHashSet();
        var candidates = platform.EnumerateWindows()
            .Where(w => w.AppID == tab.AppID && (tab.Shared == true || !held.Contains(w.Hwnd))).ToList();
        // A window we cannot hide (elevated) is the last resort.
        candidates = candidates.OrderBy(w => w.Locked).ToList();
        var pick = candidates.Find(w => w.Title == tab.Title)
                   ?? candidates.Find(w => tab.ClassName is not null && w.ClassName == tab.ClassName)
                   ?? candidates.FirstOrDefault();
        if (pick is null) return null;
        Bind(tab, pick);
        return pick;
    }

    /// <summary>Whether a window can be shown from outside: it is on screen, or hidden by us.
    /// A window its own app hid (closed to the tray: Claude, chat apps, Electron apps) counts
    /// as closed. Showing it with ShowWindow leaves a window the app believes is closed, which
    /// doesn't paint or respond; only the app can bring it back (start it again).</summary>
    public bool Open(WindowInfo info) => info.Visible || ledger.Contains(info.Hwnd);

    /// <summary>The window, if it exists and is <see cref="Open"/>.</summary>
    public WindowInfo? Live(long hwnd) => platform.Describe(hwnd) is { } info && Open(info) ? info : null;

    static void Bind(AppTab tab, WindowInfo w)
    {
        tab.Hwnd = w.Hwnd;
        tab.Title = w.Title;
        tab.ClassName = w.ClassName;
        tab.ExePath = w.ExePath ?? tab.ExePath;
    }

    /// <summary>Tabs bound to a window, in any workspace.</summary>
    public IEnumerable<(Workspace ws, AppTab tab)> TabsOf(long hwnd) =>
        state.Workspaces.SelectMany(w => w.Tabs.Where(t => t.Hwnd == hwnd).Select(t => (w, t)));

    // ───────────────────────── Switching ─────────────────────────

    public void SwitchWorkspace(Guid id)
    {
        if (id == Current.Id || Find(id) is not { } next) return;
        NoteHandoff();
        var old = Current;
        var monitors = platform.Monitors();
        // Shown on another display already: the two displays trade workspaces, windows and all.
        var swap = DisplayShowing(id);
        if (swap is not null) Capture(next);

        // Bind the new workspace first, so its windows are known before anything is hidden.
        var keep = new HashSet<long>();
        foreach (var t in next.Tabs)
            if (Resolve(t) is { } w) keep.Add(w.Hwnd);
        var showing = new HashSet<long>(keep);

        // Remember how the old workspace looked, then put it away (or hand it to the other display).
        Capture(old);
        if (swap is not null) Others[swap] = old.Id;
        keep.UnionWith(WindowsOf(Others.Values.Select(Find).OfType<Workspace>()));
        PutAwayAll(old, keep);

        state.CurrentWorkspace = next.Id;
        Frecency.RecordUse(next, clock());
        lastDwell = clock();

        if (swap is not null && Monitor(swap, monitors) is { } there)
            BringBack(old, WindowsOf([old]), there, activate: false);
        BringBack(next, showing, Monitor(state.FocusedDisplay, monitors));
        RecomputeActive();
        Save();
        Changed?.Invoke();
    }

    /// <summary>Hide a window (or minimize it, for apps that misbehave when hidden). Hiding
    /// leaves the window's position, size, maximized or snapped state alone, so nothing about
    /// it needs saving: it comes back as it was.</summary>
    void PutAway(long h, string appID)
    {
        hiddenAt[h] = (clock(), appID);
        if (state.Settings.MinimizeApps.Contains(appID, StringComparer.OrdinalIgnoreCase))
        {
            // Minimizing does change it: remember what to restore.
            if (platform.GetPlacement(h) is { State: not PlacementState.Minimized } p) minimizedFrom[h] = p;
            platform.Minimize(h);
            return;
        }
        if (platform.Stamp(h) is { } stamp) ledger.Add(h, stamp);
        platform.Hide(h);
    }

    /// <summary>Windows we minimized instead of hiding, and how they looked before.</summary>
    readonly Dictionary<long, Placement> minimizedFrom = new();

    /// <summary>Shows a workspace's windows again. They are where they were (hiding doesn't
    /// move them); only a window on another sidebar display (two displays traded workspaces,
    /// the workspace now shows elsewhere) or on a monitor that is gone is moved. Then the
    /// stacking order is restored and (when <paramref name="activate"/>) the window that had
    /// the focus gets it back.</summary>
    void BringBack(Workspace ws, HashSet<long> windows, MonitorInfo? display, bool activate = true)
    {
        foreach (var h in windows) ledger.Remove(h);
        var target = ws.ForegroundTab is { } ft ? ws.Tab(ft) : null;
        if (target?.Hwnd is null) target = null;
        target ??= ws.LastTabID is { } lt ? ws.Tab(lt) : null;
        if (target?.Hwnd is null) target = ws.Tabs.FirstOrDefault(t => t.Hwnd is not null);

        var monitors = platform.Monitors();
        var rank = (ws.ZOrder ?? []).Select((id, i) => (id, i)).ToDictionary(x => x.id, x => x.i);
        // Bottom to top: windows that were not on screen first, then the stack reversed.
        var stack = ws.Tabs
            .Where(t => t.Hwnd is { } h && windows.Contains(h))
            .DistinctBy(t => t.Hwnd)
            .OrderByDescending(t => rank.TryGetValue(t.Id, out var r) ? r : int.MaxValue)
            .Select(t => t.Hwnd!.Value).ToList();

        var moves = new List<(long, Placement)>();
        foreach (var h in stack)
        {
            if (platform.GetPlacement(h) is not { } live) continue;
            var restoring = minimizedFrom.Remove(h, out var before);
            if (restoring) live = before!;
            var placed = Place(live, monitors, display);
            if (restoring || !ReferenceEquals(placed, live)) moves.Add((h, placed));
        }
        var moved = moves.Select(x => x.Item1).ToHashSet();
        foreach (var h in windows) if (!moved.Contains(h)) platform.Show(h);
        if (moves.Count > 0) platform.ApplyLayout(moves);
        platform.Raise(stack.Where(h => platform.GetPlacement(h)?.State != PlacementState.Minimized).ToList());

        if (activate && target?.Hwnd is { } th && platform.GetPlacement(th)?.State != PlacementState.Minimized)
        {
            ws.LastTabID = target.Id;
            platform.Activate(th);
        }
    }

    /// <summary>Where a window goes now: onto <paramref name="display"/> when it sits on another
    /// display with a sidebar; fitted back on screen when its monitor is gone. Returns the same
    /// placement object when it can stay where it is. Windows on monitors without a sidebar stay.</summary>
    Placement Place(Placement p, IReadOnlyList<MonitorInfo> monitors, MonitorInfo? display)
    {
        if (display is null || p.Monitor == display.Device) return LayoutMath.Fit(p, monitors);
        var on = Monitor(p.Monitor, monitors);
        if (on is not null && state.Settings.NoSidebarMonitors.Contains(on.Device)) return LayoutMath.Fit(p, monitors);
        return LayoutMath.Relocate(p, monitors, display);
    }

    /// <summary>Records the stacking order and focus of a workspace's windows (not their
    /// placement: Windows keeps that). Called when leaving it and, debounced, when its windows
    /// change.</summary>
    public void Capture(Workspace ws)
    {
        var all = platform.EnumerateWindows();
        var order = all.Select((w, i) => (w.Hwnd, i)).GroupBy(x => x.Hwnd).ToDictionary(g => g.Key, g => g.First().i);
        var minimized = all.Where(w => w.Minimized).Select(w => w.Hwnd).ToHashSet();
        var onScreen = ws.Tabs.Where(t => t.Hwnd is { } h && order.ContainsKey(h)).ToList();
        ws.ZOrder = onScreen.OrderBy(t => order[t.Hwnd!.Value]).Select(t => t.Id).ToList();
        var fg = platform.ForegroundWindow();
        ws.ForegroundTab = ws.Tabs.Find(t => t.Hwnd == fg)?.Id
            ?? onScreen.Where(t => !minimized.Contains(t.Hwnd!.Value)).OrderBy(t => order[t.Hwnd!.Value]).FirstOrDefault()?.Id;
    }

    /// <summary>Debounced snapshot of the workspaces on screen (windows moved, minimized…).
    /// Also notices snap groups forming or breaking up, which the sidebar shows.</summary>
    public void CaptureCurrent()
    {
        foreach (var ws in Displayed) Capture(ws);
        Save();
        var groups = string.Join("|", Displayed.Select(ws =>
            string.Join(",", SnapGroups(ws).OrderBy(kv => kv.Key).Select(kv => kv.Key + ":" + kv.Value))));
        if (groups == lastGroups) return;
        lastGroups = groups;
        Changed?.Invoke();
    }

    string lastGroups = "";

    /// <summary>Show and focus a tab's window, as it is. If it is snapped together with other
    /// windows of this workspace (Windows snap layouts), the whole group comes to the front.
    /// Returns false when the tab has no window to show.</summary>
    public bool SelectTab(Guid tabID)
    {
        var ws = Current;
        if (ws.Tab(tabID) is not { } tab) return false;
        ws.LastTabID = tab.Id;
        FocusOutside = false;
        var w = Resolve(tab);
        if (w is not null) ShowTab(ws, tab);
        Save();
        Changed?.Invoke();
        return w is not null;
    }

    void ShowTab(Workspace ws, AppTab tab)
    {
        var h = tab.Hwnd!.Value;
        ledger.Remove(h);
        var group = SnapGroup(ws, h);
        if (group.Count > 1)
        {
            foreach (var g in group) { ledger.Remove(g); platform.Show(g); }
            platform.Raise(group.Where(g => g != h).ToList());
        }
        platform.Activate(h);
    }

    // ───────────────────────── Snap groups ─────────────────────────

    /// <summary>Window edges closer than this (physical pixels) touch. Snapped windows leave
    /// their invisible resize borders (7 px each side at 100 %) between them.</summary>
    const int Touch = 24;

    /// <summary>The windows of a workspace snapped together with <paramref name="hwnd"/>
    /// (itself included): snapped (Windows snap layouts, Aero Snap), on the same monitor, each
    /// touching another along an edge. Windows keeps no public record of its snap groups, so
    /// this goes by where the windows are; drag one away and it leaves the group.</summary>
    public List<long> SnapGroup(Workspace ws, long hwnd) =>
        Groups(ws).FirstOrDefault(g => g.Contains(hwnd)) ?? [hwnd];

    /// <summary>Tab id → group number, for tabs whose window is in a group of two or more.</summary>
    public Dictionary<Guid, int> SnapGroups(Workspace ws)
    {
        var result = new Dictionary<Guid, int>();
        var i = 0;
        foreach (var g in Groups(ws).Where(g => g.Count > 1))
        {
            foreach (var t in ws.Tabs.Where(t => t.Hwnd is { } h && g.Contains(h))) result[t.Id] = i;
            i++;
        }
        return result;
    }

    List<List<long>> Groups(Workspace ws)
    {
        var snapped = ws.Tabs.Select(t => t.Hwnd).OfType<long>().Distinct()
            .Where(h => Live(h) is not null)
            .Select(h => (h, p: platform.GetPlacement(h)))
            .Where(x => x.p is { State: PlacementState.Snapped })
            .Select(x => (h: x.h, r: x.p!.ActualRect, m: x.p.Monitor)).ToList();
        var groups = new List<List<long>>();
        var seen = new HashSet<long>();
        foreach (var start in snapped)
        {
            if (!seen.Add(start.h)) continue;
            var group = new List<long> { start.h };
            var queue = new Queue<(long h, Rect r, string? m)>();
            queue.Enqueue(start);
            while (queue.Count > 0)
            {
                var a = queue.Dequeue();
                foreach (var b in snapped)
                {
                    if (seen.Contains(b.h) || b.m != a.m || !Touching(a.r, b.r)) continue;
                    seen.Add(b.h);
                    group.Add(b.h);
                    queue.Enqueue(b);
                }
            }
            groups.Add(group);
        }
        return groups;
    }

    static bool Touching(Rect a, Rect b)
    {
        static bool Near(int x, int y) => Math.Abs(x - y) <= Touch;
        static bool Spans(int a0, int a1, int b0, int b1) => Math.Min(a1, b1) - Math.Max(a0, b0) > Touch;
        var side = (Near(a.Right(), b.X) || Near(b.Right(), a.X)) && Spans(a.Y, a.Bottom(), b.Y, b.Bottom());
        var stacked = (Near(a.Bottom(), b.Y) || Near(b.Bottom(), a.Y)) && Spans(a.X, a.Right(), b.X, b.Right());
        return side || stacked;
    }

    /// <summary>A window was destroyed. One that dies right after we hid it belongs to an app
    /// that cannot stand being hidden (a modal-dialog main window…): from now on that app is
    /// minimized instead.</summary>
    public void OnDestroyed(long hwnd)
    {
        if (!hiddenAt.Remove(hwnd, out var hid)) return;
        ledger.Remove(hwnd);
        if (clock() - hid.at > 3 || state.Settings.MinimizeApps.Contains(hid.appID, StringComparer.OrdinalIgnoreCase)) return;
        state.Settings.MinimizeApps.Add(hid.appID);
        Save();
        Notice?.Invoke($"A window closed itself after being hidden; from now on this app is minimized instead: {hid.appID}");
    }

    public Settings Settings => state.Settings;

    public void UpdateSettings(Action<Settings> change)
    {
        change(state.Settings);
        RecomputeActive();
        Save();
        Changed?.Invoke();
    }

    public void SelectRelative(int delta)
    {
        var tabs = Current.Tabs;
        if (tabs.Count == 0) return;
        var i = Current.LastTabID is { } id ? tabs.FindIndex(t => t.Id == id) : -1;
        SelectTab(tabs[((i + delta) % tabs.Count + tabs.Count) % tabs.Count].Id);
    }

    public void SwitchRelative(int delta)
    {
        var list = ActiveWorkspaces.ToList();
        if (list.Count < 2) return;
        var i = list.FindIndex(w => w.Id == Current.Id);
        SwitchWorkspace(list[((i + delta) % list.Count + list.Count) % list.Count].Id);
    }

    /// <summary>The user focused a window (by clicking it, Alt+Tab…): select its tab.</summary>
    public void OnForeground(long hwnd)
    {
        // A window of another display's workspace (or one sitting on another display): that
        // display's sidebar becomes the focused one.
        if (Others.Count > 0 && Current.Tabs.All(t => t.Hwnd != hwnd))
        {
            var d = Others.FirstOrDefault(kv => Find(kv.Value)?.Tabs.Any(t => t.Hwnd == hwnd) == true).Key;
            if (d is null && platform.GetPlacement(hwnd)?.Monitor is { } m && Others.ContainsKey(m)) d = m;
            if (d is not null) FocusDisplay(d);
        }
        var tab = Current.Tabs.Find(t => t.Hwnd == hwnd);
        if (tab is null)
        {
            // A window of no workspace on screen: nothing in the sidebar has the focus.
            if (FocusOutside) return;
            FocusOutside = true;
            Changed?.Invoke();
            return;
        }
        var wasOutside = FocusOutside;
        FocusOutside = false;
        if (Current.LastTabID == tab.Id) { if (wasOutside) Changed?.Invoke(); return; }
        Current.LastTabID = tab.Id;
        Current.ForegroundTab = tab.Id;
        Save();
        Changed?.Invoke();
    }

    /// <summary>The foreground window is not one of the workspace on screen (the sidebar
    /// highlights nothing).</summary>
    public bool FocusOutside { get; private set; }

    double handoffAt = double.NegativeInfinity;

    /// <summary>Focus is about to move without the user choosing the window that gets it (a
    /// window closed or minimized, TabStack hid windows): that window must not pull the
    /// sidebar to its workspace.</summary>
    public void NoteHandoff() => handoffAt = clock();

    /// <summary>The workspace to follow focus to: the window is a tab of exactly one workspace
    /// no display shows (an app brought its hidden window forward, a notification was
    /// clicked…), and focus was not just handed over.</summary>
    public Workspace? FollowTarget(long hwnd)
    {
        if (clock() - handoffAt < 1) return null;
        var shown = Displayed.Select(w => w.Id).ToHashSet();
        if (state.Workspaces.Any(w => shown.Contains(w.Id) && w.Tabs.Any(t => t.Hwnd == hwnd))) return null;
        var owners = state.Workspaces.Where(w => w.Tabs.Any(t => t.Hwnd == hwnd)).ToList();
        return owners.Count == 1 ? owners[0] : null;
    }

    /// <summary>Called a moment after focus went to <paramref name="hwnd"/>: if it is still
    /// there and still belongs only to <paramref name="id"/>, switch to that workspace with
    /// its tab selected.</summary>
    public void Follow(long hwnd, Guid id)
    {
        if (platform.ForegroundWindow() != hwnd || FollowTarget(hwnd)?.Id != id || Find(id) is not { } ws) return;
        var tab = ws.Tabs.First(t => t.Hwnd == hwnd);
        ws.LastTabID = tab.Id;
        ws.ForegroundTab = tab.Id;
        SwitchWorkspace(id);
        FocusOutside = false;
        Changed?.Invoke();
    }

    /// <summary>The selected tab's window was closed: show the neighbouring tab (the next one,
    /// else the one before) whose window is open, unless Windows already gave the focus to
    /// another window of this workspace. Nothing is launched; the closed tab stays.</summary>
    public void CoverClosed(Guid tabID, long closed)
    {
        var ws = Current;
        if (ws.LastTabID != tabID || ws.Tab(tabID) is not { } cur || Live(closed) is not null) return;
        var fg = platform.ForegroundWindow();
        if (ws.Tabs.Any(t => t.Hwnd == fg)) { OnForeground(fg); return; }
        var i = ws.Tabs.IndexOf(cur);
        var order = ws.Tabs.Skip(i + 1).Concat(ws.Tabs.Take(i).Reverse());
        var next = order.FirstOrDefault(t => t.Hwnd is { } h && h != closed && Live(h)?.AppID == t.AppID);
        if (next is not null) SelectTab(next.Id);
    }

    /// <summary>Periodic refresh: titles, closed windows, dwell-time usage.</summary>
    public void Tick()
    {
        var changed = false;
        foreach (var t in Displayed.SelectMany(w => w.Tabs))
        {
            if (t.Hwnd is not { } h) continue;
            var info = platform.Describe(h);
            if (info is null || info.AppID != t.AppID || !Open(info)) { t.Hwnd = null; changed = true; continue; }
            if (info.Title.Length > 0 && info.Title != t.Title) { t.Title = info.Title; changed = true; }
        }
        var now = clock();
        if (now - lastDwell >= Frecency.DwellInterval)
        {
            lastDwell = now;
            ledger.Prune(platform);
            Frecency.RecordUse(Current, now);
            changed = true;
        }
        if (!changed) return;
        Save();
        Changed?.Invoke();
    }

    // ───────────────────────── Editing ─────────────────────────

    public Workspace CreateWorkspace(string name)
    {
        var used = state.Workspaces.Select(w => w.Color ?? 0).ToHashSet();
        var color = Enumerable.Range(0, Palette.Length).FirstOrDefault(i => !used.Contains(i), state.Workspaces.Count % Palette.Length);
        var ws = new Workspace { Name = name, Color = color, Usage = [clock()] };
        state.Workspaces.Add(ws);
        RecomputeActive();
        Save();
        Changed?.Invoke();
        return ws;
    }

    public void RenameWorkspace(Guid id, string name) => Edit(id, w => w.Name = name);
    public void SetColor(Guid id, int color) => Edit(id, w => w.Color = color);
    public void SetPinned(Guid id, bool pinned) { Edit(id, w => w.Pinned = pinned ? true : null); RecomputeActive(); }

    /// <summary>Deletes a workspace; its hidden windows are shown again. The last one can't go.</summary>
    public void DeleteWorkspace(Guid id)
    {
        if (state.Workspaces.Count < 2 || Find(id) is not { } ws) return;
        if (ws.Id == Current.Id)
        {
            // Preferably to a workspace no display shows.
            var shown = Displayed.Select(w => w.Id).ToHashSet();
            var to = Search("").FirstOrDefault(w => !shown.Contains(w.Id)) ?? state.Workspaces.First(w => w.Id != id);
            SwitchWorkspace(to.Id);
        }
        foreach (var t in ws.Tabs)
        {
            if (t.Hwnd is not { } h || !ledger.Contains(h)) continue;
            if (TabsOf(h).Any(x => x.ws.Id != id && x.ws.Id != Current.Id)) continue; // still hidden elsewhere
            platform.Show(h);
            ledger.Remove(h);
        }
        var onOther = DisplayShowing(id);
        state.Workspaces.Remove(ws);
        if (onOther is not null) AssignDisplays();
        RecomputeActive();
        Save();
        Changed?.Invoke();
    }

    public void MoveWorkspace(Guid id, int newIndex)
    {
        var i = state.Workspaces.FindIndex(w => w.Id == id);
        if (i < 0) return;
        var ws = state.Workspaces[i];
        state.Workspaces.RemoveAt(i);
        state.Workspaces.Insert(Math.Clamp(newIndex, 0, state.Workspaces.Count), ws);
        Save();
        Changed?.Invoke();
    }

    /// <summary>Adds a window to the current workspace and selects it. Adding a window that is
    /// already a tab here just selects it.</summary>
    public AppTab AddWindow(WindowInfo w)
    {
        var ws = Current;
        var existing = ws.Tabs.Find(t => t.Hwnd == w.Hwnd);
        if (existing is not null) { SelectTab(existing.Id); return existing; }
        var tab = new AppTab { AppID = w.AppID, Name = w.AppName };
        Bind(tab, w);
        if (TabsOf(w.Hwnd).Any()) tab.Shared = true;
        foreach (var (_, other) in TabsOf(w.Hwnd)) other.Shared = true;
        ws.Tabs.Add(tab);
        ws.LastTabID = tab.Id;
        ledger.Remove(w.Hwnd);
        platform.Activate(w.Hwnd);
        Save();
        Changed?.Invoke();
        return tab;
    }

    /// <summary>Ctrl+Alt+D: closes a window and removes every tab bound to it. A window other
    /// workspaces also hold (Claude, a chat app) is not closed: it just leaves this workspace
    /// and is put out of sight. Returns false when there was nothing to close; otherwise
    /// <paramref name="next"/> is the neighbouring tab to show, like closing a browser tab.</summary>
    public bool CloseWindow(long hwnd, out Guid? next)
    {
        next = null;
        var ws = Current;
        var here = ws.Tabs.Where(t => t.Hwnd == hwnd).ToList();
        if (here.FirstOrDefault() is { } first && first.Id == ws.LastTabID && ws.Tabs.Count > 1)
        {
            var i = ws.Tabs.IndexOf(first);
            next = (i + 1 < ws.Tabs.Count ? ws.Tabs[i + 1] : ws.Tabs[i - 1]).Id;
        }
        var elsewhere = state.Workspaces.Where(w => w.Id != ws.Id && w.Tabs.Any(t => t.Hwnd == hwnd)).ToList();
        if (here.Count > 0 && elsewhere.Count > 0)
        {
            foreach (var t in here) RemoveTab(t.Id);
            if (!Others.Values.Any(id => elsewhere.Any(w => w.Id == id)) && platform.Describe(hwnd) is { Locked: false } info)
                PutAway(hwnd, info.AppID);
            if (elsewhere.Sum(w => w.Tabs.Count(t => t.Hwnd == hwnd)) == 1)
                foreach (var w in elsewhere) foreach (var t in w.Tabs.Where(t => t.Hwnd == hwnd)) t.Shared = null;
            Save();
            Changed?.Invoke();
            return true;
        }
        if (!platform.CloseWindow(hwnd)) return false;
        foreach (var w in state.Workspaces)
        {
            w.Tabs.RemoveAll(t => t.Hwnd == hwnd);
            if (w.LastTabID is { } l && w.Tab(l) is null) w.LastTabID = w.Tabs.FirstOrDefault()?.Id;
        }
        if (next is { } n) ws.LastTabID = n;
        Save();
        Changed?.Invoke();
        return true;
    }

    public void RemoveTab(Guid tabID)
    {
        var ws = Current;
        if (ws.Tab(tabID) is not { } tab) return;
        ws.Tabs.Remove(tab);
        if (ws.LastTabID == tabID) ws.LastTabID = ws.Tabs.FirstOrDefault()?.Id;
        if (tab.Hwnd is { } h)
        {
            var others = TabsOf(h).ToList();
            if (others.Count == 1) others[0].tab.Shared = null;
        }
        Save();
        Changed?.Invoke();
    }

    public void RenameTab(Guid tabID, string? name) =>
        Edit(Current.Id, w => { if (w.Tab(tabID) is { } t) t.CustomName = string.IsNullOrWhiteSpace(name) ? null : name; });

    /// <summary>Re-bind a tab to a specific window (the user picks it).</summary>
    public void BindTab(Guid tabID, WindowInfo w) =>
        Edit(Current.Id, ws => { if (ws.Tab(tabID) is { } t) { t.AppID = w.AppID; t.Name = w.AppName; Bind(t, w); } });

    public void MoveTab(Guid tabID, int newIndex) => Edit(Current.Id, ws =>
    {
        var i = ws.Tabs.FindIndex(t => t.Id == tabID);
        if (i < 0) return;
        var t = ws.Tabs[i];
        ws.Tabs.RemoveAt(i);
        ws.Tabs.Insert(Math.Clamp(newIndex, 0, ws.Tabs.Count), t);
    });

    /// <summary>Moves a tab from the current workspace to another; its window is hidden if
    /// nothing here still uses it.</summary>
    public void MoveTabToWorkspace(Guid tabID, Guid targetID)
    {
        if (targetID == Current.Id || Find(targetID) is not { } target || Current.Tab(tabID) is not { } tab) return;
        Current.Tabs.Remove(tab);
        if (Current.LastTabID == tabID) Current.LastTabID = Current.Tabs.FirstOrDefault()?.Id;
        target.Tabs.Add(tab);
        if (tab.Hwnd is { } h && !Current.Tabs.Any(t => t.Hwnd == h) && platform.Describe(h) is { Locked: false } info)
        {
            // The target is on screen on another display: move the window there instead.
            if (DisplayShowing(targetID) is { } d && Monitor(d, platform.Monitors()) is { } there)
                BringBack(target, [h], there, activate: false);
            else PutAway(h, info.AppID);
        }
        Save();
        Changed?.Invoke();
    }

    /// <summary>Shows every window TabStack has hidden (tray "Show all windows", and on exit).</summary>
    public int ShowAllHidden() => ledger.RestoreAll(platform);

    void Edit(Guid id, Action<Workspace> change)
    {
        if (Find(id) is not { } ws) return;
        change(ws);
        Save();
        Changed?.Invoke();
    }
}
