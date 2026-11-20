namespace TabStack.Core;

/// <summary>What sleeping needs from the OS beyond windows. Tests use a fake.</summary>
public interface ISleepPlatform
{
    /// <summary>Puts a process and its children in efficiency mode (EcoQoS, idle priority).
    /// Returns what to give back; empty when it could not.</summary>
    IReadOnlyList<ThrottledProcess> Throttle(int pid);

    /// <summary>Gives a process its priority back and ends efficiency mode, if it is still
    /// the same process (pids are reused).</summary>
    void Unthrottle(ThrottledProcess p);

    /// <summary>The process or one of its children is playing sound.</summary>
    bool PlayingAudio(int pid);

    /// <summary>Memory in use, in percent.</summary>
    int MemoryLoad();

    /// <summary>How to open this window again as it is, for apps whose windows can be (VS Code
    /// and forks: the folder; File Explorer: the path). Null for every other window, and for a
    /// window that would lose something if closed (unsaved changes).</summary>
    Reopen? Capture(WindowInfo w);

    /// <summary>Opens a closed tab's window again from its <see cref="AppTab.Reopen"/>.</summary>
    bool Reopen(AppTab tab);
}

/// <summary>
/// Puts workspaces you are not using to sleep (docs/windows-port.md §6). A workspace sleeps
/// once it has been off screen for <see cref="Settings.SleepAfterMinutes"/>, unless it is pinned,
/// marked never to sleep or among the <see cref="Settings.AwakeWorkspaces"/> most used.
/// <list type="bullet">
/// <item>L1: the apps of its windows run in efficiency mode. A process is only throttled when
/// every tab window it has belongs to a sleeping workspace, none of them is shared or marked
/// never to sleep, it has no window on screen and it is not playing sound.</item>
/// <item>L4: when memory runs low, the windows of the least used sleeping workspace that can be
/// reopened as they were (VS Code, File Explorer) are closed; they reopen when the workspace
/// is shown again.</item>
/// </list>
/// Call <see cref="Evaluate"/> every half minute and <see cref="WakeDisplayed"/> whenever what is
/// on screen changes. Not thread-safe: call it from the UI thread.
/// </summary>
public sealed class Sleeper
{
    /// <summary>Processes never throttled: the shell (File Explorer windows live in it).</summary>
    static readonly HashSet<string> Protected = new(StringComparer.OrdinalIgnoreCase) { "explorer.exe" };

    /// <summary>How long a window may take to close before we take it that it won't (it asked
    /// whether to save, say).</summary>
    const double CloseTimeout = 20;
    /// <summary>How long to wait for a reopened window.</summary>
    const double ReopenTimeout = 30;

    readonly WorkspaceManager m;
    readonly IWindowPlatform platform;
    readonly ISleepPlatform sleep;
    readonly Func<double> clock;
    /// <summary>When each workspace was last on screen (this run; else its last use).</summary>
    readonly Dictionary<Guid, double> seen = new();
    /// <summary>Windows asked to close, and when.</summary>
    readonly Dictionary<long, double> closing = new();
    /// <summary>Tabs whose window is being reopened: when, and the app's windows that already existed.</summary>
    readonly Dictionary<Guid, (double at, HashSet<long> before)> reopening = new();

    public Sleeper(WorkspaceManager manager, IWindowPlatform platform, ISleepPlatform sleep, Func<double>? clock = null)
    {
        m = manager;
        this.platform = platform;
        this.sleep = sleep;
        this.clock = clock ?? Frecency.Now;
        // Left over from a TabStack that crashed or was killed: give those processes back.
        if (m.Throttled.Count > 0)
        {
            foreach (var p in m.Throttled) sleep.Unthrottle(p);
            m.Throttled.Clear();
            m.Save();
        }
    }

    Settings S => m.Settings;

    public bool Reopening => reopening.Count > 0;

    /// <summary>Workspaces that may sleep now.</summary>
    public HashSet<Guid> Sleepy()
    {
        var now = clock();
        var result = new HashSet<Guid>();
        if (!S.Sleep) return result;
        var awake = m.Workspaces.OrderByDescending(w => Frecency.Score(w, now))
            .Take(Math.Max(0, S.AwakeWorkspaces)).Select(w => w.Id).ToHashSet();
        foreach (var ws in m.Workspaces)
        {
            if (m.IsDisplayed(ws.Id) || ws.Pinned == true || ws.NoSleep == true || awake.Contains(ws.Id)) continue;
            var last = seen.TryGetValue(ws.Id, out var s) ? s : ws.Usage?.LastOrDefault() ?? 0;
            if (now - last >= S.SleepAfterMinutes * 60) result.Add(ws.Id);
        }
        return result;
    }

    sealed class Proc
    {
        public readonly HashSet<Guid> Owners = new();
        public bool Keep;
        public bool Locked;
        public string? Exe;
    }

    /// <summary>Every process with a tab window, and which workspaces hold those windows.</summary>
    Dictionary<int, Proc> Processes()
    {
        var procs = new Dictionary<int, Proc>();
        foreach (var ws in m.Workspaces)
            foreach (var t in ws.Tabs)
            {
                if (t.Hwnd is not { } h || platform.Describe(h) is not { } w) continue;
                if (!procs.TryGetValue(w.Pid, out var p)) procs[w.Pid] = p = new Proc { Exe = w.ExePath };
                p.Owners.Add(ws.Id);
                p.Keep |= t.Shared == true || t.NoSleep == true || ws.NoSleep == true;
                p.Locked |= w.Locked;
            }
        return procs;
    }

    /// <summary>The periodic pass: throttle what may sleep, wake what may not, and close
    /// windows when memory is low.</summary>
    public void Evaluate()
    {
        var now = clock();
        foreach (var ws in m.Displayed) seen[ws.Id] = now;
        var changed = CheckClosing(now);
        var sleepy = Sleepy();
        var procs = Processes();
        var onScreen = platform.EnumerateWindows().Where(w => !w.Minimized).Select(w => w.Pid).ToHashSet();
        bool May(int pid, Proc p) =>
            !p.Keep && !p.Locked && !onScreen.Contains(pid) && p.Owners.All(sleepy.Contains)
            && !(p.Exe is { } e && Protected.Contains(Path.GetFileName(e)));

        var throttled = m.Throttled.Select(t => t.Root).ToHashSet();
        foreach (var root in throttled)
            if (!procs.TryGetValue(root, out var p) || !May(root, p) || sleep.PlayingAudio(root))
                changed |= Wake(root);
        foreach (var (pid, p) in procs)
        {
            if (throttled.Contains(pid) || !May(pid, p) || sleep.PlayingAudio(pid)) continue;
            var done = sleep.Throttle(pid);
            if (done.Count == 0) continue;
            m.Throttled.AddRange(done);
            changed = true;
            Log.Write($"sleep: {Path.GetFileName(p.Exe)} ({pid}) in efficiency mode");
        }

        if (S.Sleep && S.CloseWhenMemoryLow && sleepy.Count > 0 && closing.Count == 0 && sleep.MemoryLoad() >= S.MemoryLowPercent)
            changed |= CloseOne(sleepy, procs, now);

        changed |= UpdateLevels(now);
        if (changed) m.Commit();
    }

    bool Wake(int root)
    {
        var mine = m.Throttled.Where(t => t.Root == root).ToList();
        if (mine.Count == 0) return false;
        foreach (var t in mine) sleep.Unthrottle(t);
        m.Throttled.RemoveAll(t => t.Root == root);
        Log.Write($"sleep: process {root} awake");
        return true;
    }

    /// <summary>Memory is low: close the windows that can be reopened in the least used sleeping
    /// workspace that has any. One workspace per pass; the next pass sees whether that was enough.</summary>
    bool CloseOne(HashSet<Guid> sleepy, Dictionary<int, Proc> procs, double now)
    {
        var order = m.Workspaces.Where(w => sleepy.Contains(w.Id)).OrderBy(w => Frecency.Score(w, now));
        foreach (var ws in order)
        {
            var closed = 0;
            foreach (var t in ws.Tabs)
            {
                if (t.Hwnd is not { } h || t.Slept is not null || t.NoSleep == true || t.Shared == true) continue;
                if (platform.Describe(h) is not { } w || w.Locked || !procs.TryGetValue(w.Pid, out var p)) continue;
                // Another workspace that is awake uses this window's app: a shared process is fine
                // to close windows of, but not when the window itself is held elsewhere.
                if (m.TabsOf(h).Count() > 1) continue;
                if (sleep.Capture(w) is not { } recipe || platform.GetPlacement(h) is not { } placement) continue;
                t.Reopen = recipe;
                t.Slept = placement;
                closing[h] = now;
                platform.CloseWindow(h);
                closed++;
            }
            if (closed == 0) continue;
            Log.Write($"sleep: memory low ({sleep.MemoryLoad()}%), closed {closed} window(s) of {ws.Name}");
            return true;
        }
        return false;
    }

    /// <summary>Windows asked to close: gone means closed (the tab keeps its recipe); still there
    /// after a while means the app declined (unsaved changes), so the tab is left as it was.</summary>
    bool CheckClosing(double now)
    {
        var changed = false;
        foreach (var (h, at) in closing.ToList())
        {
            var tabs = m.Workspaces.SelectMany(w => w.Tabs).Where(t => t.Hwnd == h && t.Slept is not null).ToList();
            if (platform.Describe(h) is null)
            {
                foreach (var t in tabs) t.Hwnd = null;
                closing.Remove(h);
                changed = true;
            }
            else if (now - at > CloseTimeout)
            {
                foreach (var t in tabs) t.Slept = null;
                closing.Remove(h);
                Log.Write($"sleep: window {h} did not close; left open");
                changed = true;
            }
        }
        return changed;
    }

    /// <summary>The sleep level each workspace shows (moon in the workspace list).</summary>
    bool UpdateLevels(double now)
    {
        var throttled = m.Throttled.Select(t => t.Root).ToHashSet();
        var changed = false;
        foreach (var ws in m.Workspaces)
        {
            var level = ws.Tabs.Any(t => t.Slept is not null) ? SleepLevel.Closed
                : ws.Tabs.Any(t => t.Hwnd is { } h && platform.Describe(h) is { } w && throttled.Contains(w.Pid)) ? SleepLevel.Throttled
                : SleepLevel.Awake;
            if ((ws.Sleep?.Level ?? SleepLevel.Awake) == level) continue;
            ws.Sleep = level == SleepLevel.Awake ? null : new SleepState { Level = level, Since = now };
            changed = true;
        }
        return changed;
    }

    /// <summary>What is on screen changed (a workspace was switched to, displays swapped):
    /// wake the processes of the workspaces shown and reopen their closed windows. Cheap enough
    /// to call on every change.</summary>
    public void WakeDisplayed()
    {
        var now = clock();
        var changed = false;
        var throttled = m.Throttled.Select(t => t.Root).ToHashSet();
        foreach (var ws in m.Displayed)
        {
            seen[ws.Id] = now;
            foreach (var t in ws.Tabs)
            {
                if (throttled.Count > 0 && t.Hwnd is { } h && platform.Describe(h) is { } w && throttled.Contains(w.Pid))
                {
                    changed |= Wake(w.Pid);
                    throttled.Remove(w.Pid);
                }
                if (t.Slept is not null && t.Hwnd is null) StartReopen(t, now);
            }
        }
        changed |= UpdateLevels(now);
        if (changed) m.Commit();
    }

    /// <summary>Reopens one tab's window (clicking a tab whose window sleep closed).</summary>
    public bool StartReopen(AppTab t) => StartReopen(t, clock());

    bool StartReopen(AppTab t, double now)
    {
        if (t.Slept is null || t.Hwnd is not null) return false;
        if (reopening.TryGetValue(t.Id, out var r) && now - r.at < ReopenTimeout) return true;
        var before = platform.EnumerateWindows().Where(w => w.AppID == t.AppID).Select(w => w.Hwnd).ToHashSet();
        if (!sleep.Reopen(t))
        {
            // Nothing to open it from any more (the folder is gone): an ordinary closed tab.
            t.Slept = null;
            m.Commit();
            return false;
        }
        reopening[t.Id] = (now, before);
        return true;
    }

    /// <summary>Binds reopened windows to their tabs as they appear. Call often while
    /// <see cref="Reopening"/>.</summary>
    public void Adopt()
    {
        var now = clock();
        var held = m.Workspaces.SelectMany(w => w.Tabs).Select(t => t.Hwnd).OfType<long>().ToHashSet();
        List<WindowInfo>? windows = null;
        foreach (var (id, r) in reopening.ToList())
        {
            var t = m.Workspaces.SelectMany(w => w.Tabs).FirstOrDefault(x => x.Id == id);
            if (t is null || t.Slept is null || t.Hwnd is not null || now - r.at > ReopenTimeout)
            {
                if (t?.Slept is not null && t.Hwnd is null) Log.Write($"sleep: {t.DisplayName} did not reopen in time");
                reopening.Remove(id);
                continue;
            }
            windows ??= platform.EnumerateWindows().ToList();
            var fresh = windows.Where(w => w.AppID == t.AppID && !r.before.Contains(w.Hwnd) && !held.Contains(w.Hwnd)).ToList();
            var name = Path.GetFileName((t.Reopen?.Folder ?? t.Reopen?.Document ?? "").TrimEnd('\\', '/'));
            var pick = fresh.Find(w => Words.Has(w.Title, name)) ?? (name.Length == 0 ? fresh.FirstOrDefault() : null);
            if (pick is null) continue;
            m.BindReopened(t, pick);
            held.Add(pick.Hwnd);
            reopening.Remove(id);
            if (UpdateLevels(now)) m.Commit();
        }
    }

    /// <summary>TabStack is quitting: every throttled process gets its priority back.</summary>
    public void WakeAll()
    {
        foreach (var p in m.Throttled) sleep.Unthrottle(p);
        m.Throttled.Clear();
        foreach (var ws in m.Workspaces.Where(w => w.Sleep?.Level == SleepLevel.Throttled)) ws.Sleep = null;
        m.Save();
    }
}
