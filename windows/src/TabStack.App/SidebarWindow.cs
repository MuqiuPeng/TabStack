using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using TabStack.Core;
using TabStack.Platform.Windows;

namespace TabStack.App;

/// <summary>The bar docked to the left edge: current workspace on top, its tabs below, add and
/// settings at the bottom. Built in code: it is small and redrawn whole on every change.</summary>
sealed class SidebarWindow : Window
{
    public const int WidthDip = 64;

    static readonly Brush Background0 = Frozen(Color.FromRgb(0x1E, 0x1F, 0x22));
    static readonly Brush Hover = Frozen(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF));
    static readonly Brush Selected = Frozen(Color.FromArgb(0x50, 0xFF, 0xFF, 0xFF));
    static readonly Brush Foreground0 = Frozen(Color.FromRgb(0xE6, 0xE6, 0xE6));

    readonly AppShell shell;
    readonly StackPanel tabsPanel = new();
    readonly Button workspaceButton;
    AppBar? appBar;
    HwndSource? source;

    public nint Handle { get; private set; }
    public HotKeys? HotKeys { get; set; }

    WorkspaceManager M => shell.Manager;

    public SidebarWindow(AppShell shell)
    {
        this.shell = shell;
        Title = "TabStack";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = false;
        Background = Background0;
        Width = WidthDip;
        Height = SystemParameters.PrimaryScreenHeight;
        Left = 0;
        Top = 0;

        workspaceButton = new Button { Height = 56, Margin = new Thickness(4, 8, 4, 4), ToolTip = "工作区" };
        workspaceButton.Click += (_, _) => OpenMenu(workspaceButton, WorkspaceMenu());

        var add = IconButton("＋", "添加窗口到当前工作区");
        add.Click += (_, _) => OpenMenu(add, AddMenu());
        var gear = IconButton("⚙", "工作区与设置");
        gear.Click += (_, _) => OpenMenu(gear, SettingsMenu());

        var bottom = new StackPanel { Margin = new Thickness(0, 4, 0, 8) };
        bottom.Children.Add(add);
        bottom.Children.Add(gear);

        var root = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(workspaceButton, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        root.Children.Add(workspaceButton);
        root.Children.Add(bottom);
        root.Children.Add(new ScrollViewer
        {
            Content = tabsPanel,
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        });
        Content = root;

        SourceInitialized += (_, _) => OnSourceInitialized();
        Loaded += (_, _) => Rebuild();
    }

    void OnSourceInitialized()
    {
        Handle = new WindowInteropHelper(this).Handle;
        SidebarStyle.Apply(Handle);
        source = HwndSource.FromHwnd(Handle);
        source.AddHook(WndProc);
        appBar = new AppBar(Handle);
        appBar.FullScreenChanged += full => SidebarStyle.SetTopmost(Handle, !full);
        appBar.Dock(WidthDip);
        M.Changed += () => Dispatcher.BeginInvoke(Rebuild, DispatcherPriority.Background);
        SystemEvents_DisplayChanged();
    }

    /// <summary>Re-dock when displays or DPI change.</summary>
    void SystemEvents_DisplayChanged() =>
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (_, _) => Dispatcher.BeginInvoke(() => appBar?.Dock(WidthDip));

    nint WndProc(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        const int WM_DPICHANGED = 0x02E0, WM_MOUSEACTIVATE = 0x0021, MA_NOACTIVATE = 3;
        if (appBar?.WndProc((uint)msg, wParam, lParam) == true) { handled = true; return 0; }
        if (HotKeys?.WndProc((uint)msg, wParam) == true) { handled = true; return 0; }
        if (msg == WM_MOUSEACTIVATE) { handled = true; return MA_NOACTIVATE; }
        if (msg == WM_DPICHANGED) Dispatcher.BeginInvoke(() => appBar?.Dock(WidthDip));
        return 0;
    }

    public void Undock()
    {
        appBar?.Dispose();
        appBar = null;
    }

    // ───────────────────────── Drawing ─────────────────────────

    void Rebuild()
    {
        var ws = M.Current;
        workspaceButton.Content = WorkspaceBadge(ws, 40);
        workspaceButton.ToolTip = $"工作区：{ws.Name}（点击切换）";
        workspaceButton.Style = FlatStyle();

        tabsPanel.Children.Clear();
        foreach (var tab in ws.Tabs) tabsPanel.Children.Add(TabButton(ws, tab));
    }

    static Brush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }

    static Brush WorkspaceBrush(Workspace ws) =>
        Frozen((Color)ColorConverter.ConvertFromString(WorkspaceManager.Palette[(ws.Color ?? 0) % WorkspaceManager.Palette.Length]));

    static FrameworkElement WorkspaceBadge(Workspace ws, double size) => new Border
    {
        Width = size, Height = size, CornerRadius = new CornerRadius(size / 4),
        Background = WorkspaceBrush(ws),
        Child = new TextBlock
        {
            Text = ws.Name.Length > 0 ? ws.Name[..(char.IsSurrogate(ws.Name[0]) ? 2 : 1)].ToUpperInvariant() : "?",
            Foreground = Brushes.White, FontSize = size * 0.45, FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        },
    };

    FrameworkElement TabButton(Workspace ws, AppTab tab)
    {
        var info = tab.Hwnd is { } h ? shell.Platform.Describe(h) : null;
        var selected = ws.LastTabID == tab.Id;
        var image = IconCache.For(info?.ExePath ?? tab.ExePath);
        FrameworkElement glyph = image is not null
            ? new Image { Source = image, Width = 28, Height = 28 }
            : new TextBlock
            {
                Text = tab.Name.Length > 0 ? tab.Name[..1].ToUpperInvariant() : "?", FontSize = 18,
                Foreground = Foreground0, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            };
        var grid = new Grid { Width = 56, Height = 48 };
        grid.Children.Add(new Border
        {
            Width = 3, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 10, 0, 10),
            CornerRadius = new CornerRadius(1.5), Background = selected ? WorkspaceBrush(ws) : Brushes.Transparent,
        });
        grid.Children.Add(glyph);
        if (info?.Locked == true)
            grid.Children.Add(new TextBlock { Text = "🔒", FontSize = 10, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 6, 4) });
        if (tab.PairedWith is not null)
            grid.Children.Add(new TextBlock { Text = "◫", FontSize = 10, Foreground = Foreground0, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(6, 0, 0, 4) });
        if (tab.Shared == true)
            grid.Children.Add(new TextBlock { Text = "⧉", FontSize = 10, Foreground = Foreground0, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 4, 6, 0) });

        var tip = tab.DisplayName;
        if (info is null) tip += "\n（窗口未打开：点击时按标题重新寻找，找不到就启动应用）";
        if (info?.Locked == true) tip += "\n（以管理员身份运行：TabStack 无法隐藏它）";
        var b = new Button
        {
            Content = grid, ToolTip = tip, Margin = new Thickness(4, 2, 4, 2), Style = FlatStyle(selected),
            Opacity = info is null ? 0.45 : 1,
        };
        b.Click += (_, _) => ClickTab(tab);
        b.MouseRightButtonUp += (_, e) => { e.Handled = true; OpenMenu(b, TabMenu(tab)); };
        return b;
    }

    void ClickTab(AppTab tab)
    {
        if (M.SelectTab(tab.Id)) return;
        // No window to bind: start the app and bind the first window it opens.
        var exe = tab.ExePath ?? (File.Exists(tab.AppID) ? tab.AppID : null);
        if (exe is null) return;
        try { Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true }); }
        catch (Exception e) { Log.Write($"launch {exe}: {e.Message}"); return; }
        var deadline = DateTime.Now.AddSeconds(15);
        var poll = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        poll.Tick += (_, _) =>
        {
            if (M.Current.Tab(tab.Id) is null || DateTime.Now > deadline || M.SelectTab(tab.Id)) poll.Stop();
        };
        poll.Start();
    }

    static Button IconButton(string text, string tip) => new()
    {
        Content = new TextBlock { Text = text, FontSize = 20, Foreground = Foreground0, HorizontalAlignment = HorizontalAlignment.Center },
        ToolTip = tip, Height = 40, Margin = new Thickness(4, 2, 4, 2), Style = FlatStyle(),
    };

    /// <summary>A borderless button that only shows a rounded hover/selection background.</summary>
    static Style FlatStyle(bool selected = false)
    {
        var border = new FrameworkElementFactory(typeof(Border), "bg");
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(8));
        border.SetValue(Border.BackgroundProperty, selected ? Selected : Brushes.Transparent);
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        content.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(content);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = border };
        if (!selected)
        {
            var hover = new Trigger { Property = IsMouseOverProperty, Value = true };
            hover.Setters.Add(new Setter(Border.BackgroundProperty, Hover, "bg"));
            template.Triggers.Add(hover);
        }
        var style = new Style(typeof(Button));
        style.Setters.Add(new Setter(TemplateProperty, template));
        style.Setters.Add(new Setter(CursorProperty, Cursors.Hand));
        style.Setters.Add(new Setter(FocusableProperty, false));
        return style;
    }

    // ───────────────────────── Menus ─────────────────────────

    /// <summary>A WPF popup closes at once unless its owner window is active, so the sidebar
    /// takes the foreground while a menu is open and hands it back afterwards (unless the
    /// chosen command moved it somewhere else).</summary>
    void OpenMenu(FrameworkElement anchor, ContextMenu menu)
    {
        var previous = shell.Platform.ForegroundWindow();
        Activate();
        menu.PlacementTarget = anchor;
        menu.Placement = PlacementMode.Right;
        menu.Closed += (_, _) => Dispatcher.BeginInvoke(() =>
        {
            if (shell.Platform.ForegroundWindow() == Handle && previous != 0 && previous != Handle)
                shell.Platform.Activate(previous);
        }, DispatcherPriority.Background);
        menu.IsOpen = true;
    }

    static MenuItem Item(string header, Action? click, bool enabled = true, bool check = false, object? icon = null)
    {
        var mi = new MenuItem { Header = header, IsEnabled = enabled, IsChecked = check, Icon = icon };
        if (click is not null) mi.Click += (_, _) => click();
        return mi;
    }

    ContextMenu WorkspaceMenu()
    {
        var menu = new ContextMenu();
        foreach (var ws in M.ActiveWorkspaces)
            menu.Items.Add(WorkspaceItem(ws));
        var stored = M.Search("").Where(w => !M.ActiveIDs.Contains(w.Id)).ToList();
        if (stored.Count > 0)
        {
            var more = new MenuItem { Header = $"其他工作区（{stored.Count}）" };
            foreach (var ws in stored) more.Items.Add(WorkspaceItem(ws));
            menu.Items.Add(more);
        }
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("新建工作区…", NewWorkspace));
        return menu;
    }

    MenuItem WorkspaceItem(Workspace ws)
    {
        var index = M.ActiveWorkspaces.ToList().FindIndex(w => w.Id == ws.Id);
        var mi = Item(ws.Name, () => M.SwitchWorkspace(ws.Id), check: ws.Id == M.Current.Id, icon: WorkspaceBadge(ws, 16));
        if (index is >= 0 and < 9) mi.InputGestureText = $"Ctrl+Alt+{index + 1}";
        return mi;
    }

    void NewWorkspace()
    {
        var name = InputDialog.Ask("新建工作区", "名称：", $"工作区 {M.Workspaces.Count + 1}");
        if (string.IsNullOrWhiteSpace(name)) return;
        M.SwitchWorkspace(M.CreateWorkspace(name.Trim()).Id);
    }

    ContextMenu AddMenu()
    {
        var menu = new ContextMenu();
        var here = M.Current.Tabs.Select(t => t.Hwnd).ToHashSet();
        var groups = shell.Platform.EnumerateWindows().Where(w => !here.Contains(w.Hwnd))
            .GroupBy(w => w.AppID).OrderBy(g => g.First().AppName, StringComparer.CurrentCultureIgnoreCase);
        foreach (var g in groups)
        {
            var first = g.First();
            var icon = IconCache.For(first.ExePath) is { } src ? new Image { Source = src, Width = 16, Height = 16 } : null;
            if (g.Count() == 1)
            {
                menu.Items.Add(Item($"{first.AppName} — {Short(first.Title)}", () => M.AddWindow(first), icon: icon));
                continue;
            }
            var sub = new MenuItem { Header = first.AppName, Icon = icon };
            foreach (var w in g) sub.Items.Add(Item(Short(w.Title), () => M.AddWindow(w)));
            menu.Items.Add(sub);
        }
        if (menu.Items.Count == 0) menu.Items.Add(Item("没有其他打开的窗口", null, enabled: false));
        return menu;
    }

    static string Short(string s) => s.Length > 60 ? s[..57] + "…" : s;

    ContextMenu TabMenu(AppTab tab)
    {
        var menu = new ContextMenu();
        menu.Items.Add(Item("重命名…", () =>
        {
            var name = InputDialog.Ask("重命名标签", "名称（留空则显示窗口标题）：", tab.CustomName ?? tab.DisplayName);
            if (name is not null) M.RenameTab(tab.Id, name);
        }));
        var bind = new MenuItem { Header = "绑定到窗口" };
        foreach (var w in shell.Platform.EnumerateWindows().OrderBy(w => w.AppID != tab.AppID).Take(30))
            bind.Items.Add(Item($"{w.AppName} — {Short(w.Title)}", () => M.BindTab(tab.Id, w), check: w.Hwnd == tab.Hwnd));
        menu.Items.Add(bind);
        var move = new MenuItem { Header = "移到工作区" };
        foreach (var ws in M.Workspaces.Where(w => w.Id != M.Current.Id))
            move.Items.Add(Item(ws.Name, () => M.MoveTabToWorkspace(tab.Id, ws.Id), icon: WorkspaceBadge(ws, 16)));
        move.IsEnabled = move.Items.Count > 0;
        menu.Items.Add(move);
        var others = M.Current.Tabs.Where(t => t.Id != tab.Id).ToList();
        if (tab.PairedWith is not null)
            menu.Items.Add(Item("取消并排", () => M.Unpair(tab.Id)));
        else if (others.Count > 0)
        {
            var pair = new MenuItem { Header = "与…并排（平铺模式下左右分屏）" };
            foreach (var o in others) pair.Items.Add(Item(Short(o.DisplayName), () => M.Pair(tab.Id, o.Id)));
            menu.Items.Add(pair);
        }
        var i = M.Current.Tabs.FindIndex(t => t.Id == tab.Id);
        menu.Items.Add(Item("上移", () => M.MoveTab(tab.Id, i - 1), enabled: i > 0));
        menu.Items.Add(Item("下移", () => M.MoveTab(tab.Id, i + 1), enabled: i < M.Current.Tabs.Count - 1));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("从工作区移除", () => M.RemoveTab(tab.Id)));
        return menu;
    }

    ContextMenu SettingsMenu()
    {
        var ws = M.Current;
        var menu = new ContextMenu();
        menu.Items.Add(Item("新建工作区…", NewWorkspace));
        menu.Items.Add(Item($"重命名“{ws.Name}”…", () =>
        {
            var name = InputDialog.Ask("重命名工作区", "名称：", ws.Name);
            if (!string.IsNullOrWhiteSpace(name)) M.RenameWorkspace(ws.Id, name.Trim());
        }));
        var colors = new MenuItem { Header = "颜色" };
        for (var c = 0; c < WorkspaceManager.Palette.Length; c++)
        {
            var color = c;
            colors.Items.Add(Item(WorkspaceManager.Palette[c], () => M.SetColor(ws.Id, color), check: (ws.Color ?? 0) == c,
                icon: new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(3), Background = WorkspaceBrush(new Workspace { Color = c }) }));
        }
        menu.Items.Add(colors);
        menu.Items.Add(Item("固定在侧边栏", () => M.SetPinned(ws.Id, ws.Pinned != true), check: ws.Pinned == true));
        menu.Items.Add(Item("平铺模式（标签铺满侧边栏右侧）", () => M.SetTiled(ws.Id, ws.Tiled != true), check: ws.Tiled == true));
        var idx = M.Workspaces.ToList().FindIndex(w => w.Id == ws.Id);
        menu.Items.Add(Item("上移工作区", () => M.MoveWorkspace(ws.Id, idx - 1), enabled: idx > 0));
        menu.Items.Add(Item("下移工作区", () => M.MoveWorkspace(ws.Id, idx + 1), enabled: idx < M.Workspaces.Count - 1));
        menu.Items.Add(Item($"删除“{ws.Name}”…", () =>
        {
            if (MessageBox.Show($"删除工作区“{ws.Name}”？其中的窗口不会被关闭。", "TabStack", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK)
                M.DeleteWorkspace(ws.Id);
        }, enabled: M.Workspaces.Count > 1));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("显示所有隐藏的窗口", () => shell.ShowAllHidden()));
        menu.Items.Add(Item("设置…", shell.OpenSettings));
        menu.Items.Add(Item("退出 TabStack", shell.Quit));
        return menu;
    }
}
