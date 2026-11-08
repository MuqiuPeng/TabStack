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

    static MonitorInfo? Monitor(string? device, IReadOnlyList<MonitorInfo> monitors) =>
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
            if (platform.Describe(h) is not { } info || info.Locked) continue;
            PutAway(h, info.AppID);
        }
    }

    public List<Workspace> Search(string query) => Frecency.Search(state.Workspaces, query, clock());

    // ───────────────────────── Binding ─────────────────────────

    /// <summary>Drop handles that no longer name the same app's window (after a restart).</summary>
    void ValidateBindings()
    {
        foreach (var t in state.Workspaces.SelectMany(w => w.Tabs))
        {
            if (t.Hwnd is { } h && platform.Describe(h)?.AppID != t.AppID)
                t.Hwnd = null;
        }
    }

    /// <summary>The live window of a tab, re-binding it if its window is gone: same app and
    /// title first, else a window of the app no other tab holds.</summary>
    public WindowInfo? Resolve(AppTab tab)
    {
        if (tab.Hwnd is { } h)
        {
            if (platform.Describe(h) is { } info && info.AppID == tab.AppID) return info;
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

    /// <summary>Hide a window (or minimize it, for apps that misbehave when hidden).</summary>
    void PutAway(long h, string appID)
    {
        hiddenAt[h] = (clock(), appID);
        if (state.Settings.MinimizeApps.Contains(appID, StringComparer.OrdinalIgnoreCase))
        {
            platform.Minimize(h);
            return;
        }
        if (platform.Stamp(h) is { } stamp) ledger.Add(h, stamp);
        platform.Hide(h);
    }

    /// <summary>Shows a workspace's windows where they were when it was left, in the same
    /// stacking order, and (when <paramref name="activate"/>) focuses the window that had the
    /// focus. Windows last seen on another sidebar display are moved onto <paramref name="display"/>.</summary>
    void BringBack(Workspace ws, HashSet<long> windows, MonitorInfo? display, bool activate = true)
    {
        foreach (var h in windows) ledger.Remove(h);
        var target = ws.ForegroundTab is { } ft ? ws.Tab(ft) : null;
        if (target?.Hwnd is null) target = null;
        target ??= ws.LastTabID is { } lt ? ws.Tab(lt) : null;
        if (target?.Hwnd is null) target = ws.Tabs.FirstOrDefault(t => t.Hwnd is not null);

        if (ws.Tiled == true)
        {
            foreach (var h in windows) platform.Show(h);
            if (target is not null) ShowTab(ws, target, activate, display);
            return;
        }

        var monitors = platform.Monitors();
        var rank = (ws.ZOrder ?? []).Select((id, i) => (id, i)).ToDictionary(x => x.id, x => x.i);
        var layout = ws.Tabs
            .Where(t => t.Hwnd is { } h && windows.Contains(h) && t.Placement is not null)
            .DistinctBy(t => t.Hwnd)
            // Bottom to top: windows that were not on screen first, then the stack reversed.
            .OrderByDescending(t => rank.TryGetValue(t.Id, out var r) ? r : int.MaxValue)
            .Select(t => (t.Hwnd!.Value, Place(t.Placement!, monitors, display)))
            .ToList();
        var placed = layout.Select(x => x.Item1).ToHashSet();
        foreach (var h in windows) if (!placed.Contains(h)) platform.Show(h);
        platform.ApplyLayout(layout);

        if (activate && target?.Hwnd is { } th && target.Placement?.State != PlacementState.Minimized)
        {
            ws.LastTabID = target.Id;
            platform.Activate(th);
        }
    }

    /// <summary>Where a saved placement goes now: onto <paramref name="display"/> when it was
    /// on another display with a sidebar (or one that is gone); otherwise just fitted to the
    /// current monitors. Windows on monitors without a sidebar stay there.</summary>
    Placement Place(Placement p, IReadOnlyList<MonitorInfo> monitors, MonitorInfo? display)
    {
        if (display is null || p.Monitor == display.Device) return LayoutMath.Fit(p, monitors);
        var saved = Monitor(p.Monitor, monitors);
        if (saved is not null && state.Settings.NoSidebarMonitors.Contains(saved.Device)) return LayoutMath.Fit(p, monitors);
        return LayoutMath.Relocate(p, monitors, display);
    }

    /// <summary>Records the placement, stacking order and focus of a workspace's windows.
    /// Called when leaving it and, debounced, whenever its windows move.</summary>
    public void Capture(Workspace ws)
    {
        var order = platform.EnumerateWindows().Select((w, i) => (w.Hwnd, i))
            .GroupBy(x => x.Hwnd).ToDictionary(g => g.Key, g => g.First().i);
        var onScreen = ws.Tabs.Where(t => t.Hwnd is { } h && order.ContainsKey(h)).ToList();
        foreach (var t in onScreen)
            if (platform.GetPlacement(t.Hwnd!.Value) is { } p) t.Placement = p;
        ws.ZOrder = onScreen.OrderBy(t => order[t.Hwnd!.Value]).Select(t => t.Id).ToList();
        var fg = platform.ForegroundWindow();
        ws.ForegroundTab = ws.Tabs.Find(t => t.Hwnd == fg)?.Id
            ?? onScreen.Where(t => t.Placement?.Visible == true).OrderBy(t => order[t.Hwnd!.Value]).FirstOrDefault()?.Id;
    }

    /// <summary>Debounced snapshot of the current workspace (windows moved, minimized…).</summary>
    public void CaptureCurrent()
    {
        foreach (var ws in Displayed) Capture(ws);
        Save();
    }

    /// <summary>Show and focus a tab's window. Free mode: it keeps its own position; tiling
    /// mode: it fills the work area (a pair splits it). Returns false when the tab has no
    /// window to show.</summary>
    public bool SelectTab(Guid tabID)
    {
        var ws = Current;
        if (ws.Tab(tabID) is not { } tab) return false;
        ws.LastTabID = tab.Id;
        var w = Resolve(tab);
        if (w is not null) ShowTab(ws, tab, activate: true);
        Save();
        Changed?.Invoke();
        return w is not null;
    }

    void ShowTab(Workspace ws, AppTab tab, bool activate, MonitorInfo? display = null)
    {
        var h = tab.Hwnd!.Value;
        ledger.Remove(h);
        if (ws.Tiled != true)
        {
            if (activate) platform.Activate(h);
            else platform.Show(h);
            return;
        }
        var partner = tab.PairedWith is { } pid ? ws.Tab(pid) : null;
        var ph = partner is not null ? Resolve(partner)?.Hwnd : null;
        var work = (display ?? DisplayOf(ws, platform.Monitors()))?.WorkArea ?? platform.WorkArea(h);
        if (ph is { } p && p != h)
        {
            // The member listed first goes on the left, whichever of the two was clicked.
            var left = ws.Tabs.IndexOf(tab) < ws.Tabs.IndexOf(partner!);
            ledger.Remove(p);
            platform.MoveTo(h, LayoutMath.Tile(work, left ? -1 : 1));
            platform.MoveTo(p, LayoutMath.Tile(work, left ? 1 : -1));
            if (activate) platform.Activate(p);
            else platform.Show(p);
        }
        else platform.MoveTo(h, work);
        if (activate) platform.Activate(h);
        else platform.Show(h);
    }

    public void SetTiled(Guid id, bool tiled)
    {
        Edit(id, w => w.Tiled = tiled ? true : null);
        if (tiled && id == Current.Id && Current.LastTabID is { } t) SelectTab(t);
    }

    /// <summary>Shows two tabs side by side in tiling mode.</summary>
    public void Pair(Guid a, Guid b)
    {
        if (a == b || Current.Tab(a) is not { } ta || Current.Tab(b) is not { } tb) return;
        Unpair(a, save: false);
        Unpair(b, save: false);
        ta.PairedWith = b;
        tb.PairedWith = a;
        if (Current.Tiled == true) SelectTab(a);
        else { Save(); Changed?.Invoke(); }
    }

    public void Unpair(Guid a, bool save = true)
    {
        if (Current.Tab(a) is not { } ta) return;
        if (ta.PairedWith is { } b && Current.Tab(b) is { } tb) tb.PairedWith = null;
        ta.PairedWith = null;
        if (!save) return;
        Save();
        Changed?.Invoke();
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
        Notice?.Invoke($"有个窗口被隐藏后自己关闭了，以后切走时改为最小化这个应用：{hid.appID}");
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
        if (tab is null || Current.LastTabID == tab.Id) return;
        Current.LastTabID = tab.Id;
        Current.ForegroundTab = tab.Id;
        Save();
        Changed?.Invoke();
    }

    /// <summary>Periodic refresh: titles, closed windows, dwell-time usage.</summary>
    public void Tick()
    {
        var changed = false;
        foreach (var t in Displayed.SelectMany(w => w.Tabs))
        {
            if (t.Hwnd is not { } h) continue;
            var info = platform.Describe(h);
            if (info is null || info.AppID != t.AppID) { t.Hwnd = null; changed = true; continue; }
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
        var ws = new Workspace { Name = name, Color = color, Usage = [clock()], Tiled = state.Settings.TileNewWorkspaces ? true : null };
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
            if (platform.GetPlacement(h) is { } p) tab.Placement = p;
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
