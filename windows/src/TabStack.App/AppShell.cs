using System.IO;
using System.Windows;
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
    SidebarWindow? sidebar;
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
    }

    public WorkspaceManager Manager => manager!;
    public WindowsPlatform Platform => platform;
    /// <summary>Hotkeys that could not be registered (taken by another app), by action id.</summary>
    public HashSet<string> FailedHotKeys { get; } = new();

    public void Start()
    {
        manager = new WorkspaceManager(platform, new Store(Path.Combine(Store.DefaultDirectory, "state.json")), ledger);
        sidebar = new SidebarWindow(this);
        sidebar.Show();
        tray = new Tray(this);
        manager.Notice += text => { Log.Write(text); tray.Notify(text); };

        events = new WinEvents();
        events.Foreground += h => { manager.OnForeground(h); if (InCurrent(h)) ScheduleCapture(); };
        events.LayoutChanged += h => { if (InCurrent(h)) ScheduleCapture(); };
        events.TitleChanged += h => { if (InCurrent(h)) ScheduleRefresh(); };
        events.Destroyed += h =>
        {
            manager.OnDestroyed(h);
            if (manager.TabsOf(h).Any()) ScheduleRefresh();
        };

        RegisterHotKeys();

        timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        timer.Tick += (_, _) => manager.Tick();
        timer.Start();
        Log.Write("started");
    }

    bool InCurrent(long h) => manager!.Current.Tabs.Any(t => t.Hwnd == h);

    /// <summary>Coalesces bursts of title/destroy events into one refresh.</summary>
    void ScheduleRefresh() => Debounce(ref refresh, 300, () => manager!.Tick());

    /// <summary>Keeps the current workspace's layout snapshot fresh (500 ms after the last move),
    /// so a crash loses at most that much.</summary>
    void ScheduleCapture() => Debounce(ref capture, 500, () => manager!.CaptureCurrent());

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
        hotkeys = new HotKeys(sidebar!.Handle);
        sidebar.HotKeys = hotkeys;
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
            if (m.Current.Tabs.ElementAtOrDefault(t - 1) is { } tab) m.SelectTab(tab.Id);
        }
        else switch (id)
        {
            case "prevTab": m.SelectRelative(-1); break;
            case "nextTab": m.SelectRelative(1); break;
            case "prevWorkspace": m.SwitchRelative(-1); break;
            case "nextWorkspace": m.SwitchRelative(1); break;
            case "addWindow": AddForeground(); break;
            case "toggleTile": m.SetTiled(m.Current.Id, m.Current.Tiled != true); break;
        }
    }

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
        hotkeys?.Dispose();
        events?.Dispose();
        var shown = ShowAllHidden();
        manager?.Save();
        tray?.Dispose();
        sidebar?.Undock();
        Log.Write($"stopped; showed {shown} hidden window(s)");
    }
}
