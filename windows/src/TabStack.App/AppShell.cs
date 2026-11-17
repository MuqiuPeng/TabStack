using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using TabStack.Core;
using TabStack.Platform.Windows;

namespace TabStack.App;

/// <summary>Wires the workspace logic to the sidebar, tray, hotkeys and window events.</summary>
public sealed class AppShell
{
    readonly WindowsPlatform platform;
    readonly HiddenLedger ledger;
    WorkspaceManager? manager;
    /// <summary>One sidebar per display that has one, by monitor id.</summary>
    readonly Dictionary<string, SidebarWindow> sidebars = new();
    /// <summary>Message-only window that receives WM_HOTKEY (sidebars come and go with monitors).</summary>
    HwndSource? hotkeyWindow;
    Tray? tray;
    WinEvents? events;
    HotKeys? hotkeys;
    DispatcherTimer? timer;
    DispatcherTimer? refresh;
    DispatcherTimer? capture;

    public AppShell(WindowsPlatform platform, HiddenLedger ledger)
    {
        this.platform = platform;
        this.ledger = ledger;
        panels = new Panels(this);
    }

    public WorkspaceManager Manager => manager!;
    readonly Panels panels;
    public WindowsPlatform Platform => platform;
    /// <summary>Hotkeys that could not be registered (taken by another app), by action id.</summary>
    public HashSet<string> FailedHotKeys { get; } = new();

    public void Start()
    {
        manager = new WorkspaceManager(platform, new Store(Path.Combine(Store.DefaultDirectory, "state.json")), ledger);
        hotkeyWindow = new HwndSource(new HwndSourceParameters("TabStackHotKeys")
        {
            ParentWindow = new IntPtr(-3), // HWND_MESSAGE
            Width = 0, Height = 0, WindowStyle = 0,
        });
        hotkeyWindow.AddHook((nint _, int msg, nint wParam, nint _, ref bool handled) =>
        {
            if (hotkeys?.WndProc((uint)msg, wParam) == true) handled = true;
            return 0;
        });
        manager.AssignDisplays();
        SyncSidebars();
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += OnDisplaysChanged;
        tray = new Tray(this);
        manager.Notice += text => { Log.Write(text); tray.Notify(text); };

        events = new WinEvents();
        events.Foreground += h =>
        {
            manager.OnForeground(h);
            if (InCurrent(h)) ScheduleCapture();
            CheckFullScreen();
            // A window of a workspace not on screen came forward: follow it there once focus
            // has stayed on it for a moment.
            if (manager.FollowTarget(h) is { } ws)
            {
                var id = ws.Id;
                After(400, () => manager.Follow(h, id));
            }
        };
        events.Minimized += _ => manager.NoteHandoff();
        events.LayoutChanged += h =>
        {
            if (InCurrent(h)) ScheduleCapture();
            if (h == platform.ForegroundWindow()) Debounce(ref fullScreen, 150, CheckFullScreen);
        };
        events.TitleChanged += h => { if (InCurrent(h)) ScheduleRefresh(); };
        events.Destroyed += h =>
        {
            if (manager.TabsOf(h).Any()) manager.NoteHandoff();
            // The selected window closed: once Windows has moved the focus, cover the gap.
            if (manager.Current.LastTabID is { } sel && manager.Current.Tab(sel)?.Hwnd == h)
                After(150, () => manager.CoverClosed(sel, h));
            manager.OnDestroyed(h);
            if (manager.TabsOf(h).Any()) ScheduleRefresh();
        };

        // An app closing its window to the tray only hides it. Treat that like closing: the
        // tab goes dim, and if it was selected the neighbouring tab shows. (Our own hiding is
        // in the ledger, so Live still sees those windows.)
        events.Hidden += h =>
        {
            if (!manager.TabsOf(h).Any()) return;
            After(150, () =>
            {
                if (manager.Live(h) is not null) return;
                manager.NoteHandoff();
                if (manager.Current.LastTabID is { } sel && manager.Current.Tab(sel)?.Hwnd == h)
                    manager.CoverClosed(sel, h);
                manager.Tick();
            });
        };

        RegisterHotKeys();

        timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        timer.Tick += (_, _) => { manager.Tick(); CheckFullScreen(); };
        timer.Start();
        Log.Write("started");
    }

    /// <summary>A window of a workspace on screen (on any display).</summary>
    bool InCurrent(long h) => manager!.Displayed.Any(w => w.Tabs.Any(t => t.Hwnd == h));

    /// <summary>Monitors came, went or changed resolution: give each its workspace and sidebar.
    /// The event comes in bursts (and before the shell has moved its windows), so wait a moment.</summary>
    void OnDisplaysChanged(object? sender, EventArgs e) =>
        Application.Current.Dispatcher.BeginInvoke(() => Debounce(ref displays, 800, () =>
        {
            manager!.AssignDisplays();
            SyncSidebars();
        }));

    DispatcherTimer? displays;

    /// <summary>Opens a sidebar on every display that should have one, re-docks the ones that
    /// stay and closes the rest.</summary>
    public void SyncSidebars()
    {
        IReadOnlyList<MonitorInfo> monitors = sidebarsHidden ? Array.Empty<MonitorInfo>() : manager!.SidebarMonitors();
        foreach (var gone in sidebars.Keys.Where(d => monitors.All(m => m.Device != d)).ToList())
        {
            sidebars[gone].Undock();
            sidebars[gone].Close();
            sidebars.Remove(gone);
        }
        foreach (var m in monitors)
        {
            if (sidebars.TryGetValue(m.Device, out var bar)) { bar.Redock(m); continue; }
            bar = new SidebarWindow(this, m);
            sidebars[m.Device] = bar;
            bar.Show();
        }
        foreach (var bar in sidebars.Values) bar.Refresh();
        Log.Write($"sidebars on {string.Join(", ", monitors.Select(m => m.Name ?? m.Device))}");
    }

    /// <summary>More than one sidebar: the focused one is marked.</summary>
    public bool ManySidebars => sidebars.Count > 1;

    /// <summary>Coalesces bursts of title/destroy events into one refresh.</summary>
    void ScheduleRefresh() => Debounce(ref refresh, 300, () => manager!.Tick());

    /// <summary>Keeps the current workspace's layout snapshot fresh (500 ms after the last move),
    /// so a crash loses at most that much.</summary>
    void ScheduleCapture() => Debounce(ref capture, 500, () => manager!.CaptureCurrent());

    static void After(int ms, Action action)
    {
        var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(ms) };
        t.Tick += (_, _) => { t.Stop(); action(); };
        t.Start();
    }

    static void Debounce(ref DispatcherTimer? t, int ms, Action action)
    {
        if (t is null)
        {
            DispatcherTimer? self = null;
            self = new DispatcherTimer(TimeSpan.FromMilliseconds(ms), DispatcherPriority.Background,
                (_, _) => { self!.Stop(); action(); }, Dispatcher.CurrentDispatcher);
            t = self;
        }
        t.Stop();
        t.Start();
    }

    /// <summary>(Re)registers every hotkey from the settings.</summary>
    public void RegisterHotKeys()
    {
        hotkeys?.Dispose();
        hotkeys = new HotKeys(hotkeyWindow!.Handle);
        FailedHotKeys.Clear();
        var m = manager!;
        foreach (var a in HotKeyMap.All)
        {
            var chord = HotKeyMap.ChordFor(m.Settings, a);
            if (HotKeyMap.Parse(chord) is not { } k) continue;
            if (!hotkeys.Register(k.mods, k.vk, () => Run(a.Id))) FailedHotKeys.Add(a.Id);
        }
        if (FailedHotKeys.Count > 0)
            Log.Write("hotkeys taken by other apps: " + string.Join(", ", FailedHotKeys.Select(id => HotKeyMap.ChordFor(m.Settings, HotKeyMap.All.First(a => a.Id == id)))));
    }

    void Run(string id)
    {
        var m = manager!;
        if (id.StartsWith("workspace") && int.TryParse(id[9..], out var w))
        {
            if (m.ActiveWorkspaces.ElementAtOrDefault(w - 1) is { } ws) m.SwitchWorkspace(ws.Id);
        }
        else if (id.StartsWith("tab") && int.TryParse(id[3..], out var t))
        {
            if (m.Current.Tabs.ElementAtOrDefault(t - 1) is { } tab) OpenTab(tab);
        }
        else switch (id)
        {
            case "prevTab": m.SelectRelative(-1); break;
            case "nextTab": m.SelectRelative(1); break;
            case "prevWorkspace": m.SwitchRelative(-1); break;
            case "nextWorkspace": m.SwitchRelative(1); break;
            case "addWindow": panels.QuickAdd(); break;
            case "search": panels.Search(); break;
            case "closeWindow": CloseForeground(); break;
            case "toggleSidebar": ToggleSidebars(); break;
        }
    }

    /// <summary>Shows a tab's window; when it has none (closed, or closed to the tray), starts
    /// its app, which brings its own window back, and selects that once it appears.</summary>
    public void OpenTab(AppTab tab)
    {
        var m = manager!;
        if (m.SelectTab(tab.Id)) return;
        if (!Launcher.Start(tab)) return;
        var deadline = DateTime.Now.AddSeconds(15);
        var poll = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        poll.Tick += (_, _) =>
        {
            if (m.Current.Tab(tab.Id) is null || DateTime.Now > deadline || m.SelectTab(tab.Id)) poll.Stop();
        };
        poll.Start();
    }

    /// <summary>Ctrl+Alt+D (Mac ⌃⌥D): close the active window and drop its tabs; the
    /// neighbouring tab then shows, as when closing a browser tab.</summary>
    void CloseForeground()
    {
        var fg = platform.ForegroundWindow();
        if (fg == 0 || platform.Describe(fg) is not { } w || w.Pid == Environment.ProcessId
            || !manager!.CloseWindow(fg, out var next))
        {
            System.Media.SystemSounds.Beep.Play();
            return;
        }
        if (next is { } id) After(300, () => manager.SelectTab(id));
    }

    /// <summary>Ctrl+Alt+0 (Mac ⌘⌥0): hide the sidebars and give their space back, or bring
    /// them back.</summary>
    public void ToggleSidebars()
    {
        sidebarsHidden = !sidebarsHidden;
        SyncSidebars();
    }

    bool sidebarsHidden;
    DispatcherTimer? fullScreen;

    /// <summary>Hides the sidebar of every display a full-screen window in front covers (a
    /// game, a video, F11), and shows it again once that window is gone or no longer in front.</summary>
    public void CheckFullScreen()
    {
        var fg = platform.ForegroundWindow();
        foreach (var bar in sidebars.Values)
            bar.SetFullScreen(platform.CoversMonitor(fg, bar.Monitor.Bounds)
                // The shell's notice is sticky and not always for this display: only trust it
                // while the window in front is on this display.
                || (bar.ShellFullScreen && fg != 0 && platform.GetPlacement(fg)?.Monitor == bar.Device));
    }
    public bool SidebarsHidden => sidebarsHidden;

    /// <summary>Adds the window in use to the current workspace (Mac ⌃⌥A, first entry).</summary>
    public void AddForeground()
    {
        var fg = platform.ForegroundWindow();
        if (platform.EnumerateWindows().FirstOrDefault(w => w.Hwnd == fg) is { } w) manager!.AddWindow(w);
    }

    SettingsWindow? settingsWindow;

    public void OpenSettings()
    {
        if (settingsWindow is { IsLoaded: true }) { settingsWindow.Activate(); return; }
        settingsWindow = new SettingsWindow(this);
        settingsWindow.Show();
        settingsWindow.Activate();
    }

    public int ShowAllHidden() => manager?.ShowAllHidden() ?? ledger.RestoreAll(platform);

    public void Quit() => Application.Current.Shutdown();

    public void Stop()
    {
        timer?.Stop();
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged -= OnDisplaysChanged;
        hotkeys?.Dispose();
        hotkeyWindow?.Dispose();
        events?.Dispose();
        var shown = ShowAllHidden();
        manager?.Save();
        tray?.Dispose();
        foreach (var bar in sidebars.Values) bar.Undock();
        Log.Write($"stopped; showed {shown} hidden window(s)");
    }
}
