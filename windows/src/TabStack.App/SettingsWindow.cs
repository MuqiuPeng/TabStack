using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using TabStack.Core;

namespace TabStack.App;

/// <summary>Settings: how many workspaces the sidebar shows, tiling default, hotkeys, and the
/// apps that are minimized instead of hidden.</summary>
sealed class SettingsWindow : Window
{
    readonly AppShell shell;
    readonly Dictionary<string, TextBox> chordBoxes = new();
    readonly ListBox minimizeList = new() { Height = 110 };
    readonly TextBox limitBox = new() { Width = 48 };
    readonly Dictionary<string, CheckBox> monitorBoxes = new();
    readonly CheckBox tileNew = new() { Content = "新建的工作区默认使用平铺模式" };
    readonly TextBlock status = new() { Foreground = Brushes.Firebrick, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };

    WorkspaceManager M => shell.Manager;

    public SettingsWindow(AppShell shell)
    {
        this.shell = shell;
        Title = "TabStack 设置";
        Width = 520;
        SizeToContent = SizeToContent.Height;
        MaxHeight = SystemParameters.WorkArea.Height - 40;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var root = new StackPanel { Margin = new Thickness(16) };

        root.Children.Add(Header("侧边栏"));
        var limitRow = new StackPanel { Orientation = Orientation.Horizontal };
        limitRow.Children.Add(new TextBlock { Text = "侧边栏显示的工作区数量：", VerticalAlignment = VerticalAlignment.Center });
        limitBox.Text = M.ActiveLimit.ToString();
        limitRow.Children.Add(limitBox);
        root.Children.Add(limitRow);
        var monitors = shell.Platform.Monitors();
        if (monitors.Count > 1)
        {
            root.Children.Add(new TextBlock { Text = "在这些显示器上显示侧边栏（每块各显示一个工作区）：", Margin = new Thickness(0, 8, 0, 2) });
            foreach (var m in monitors.OrderBy(m => m.Bounds.X))
            {
                var label = $"{m.Name ?? "显示器"}  {m.Bounds.W}×{m.Bounds.H}" + (m.Primary ? "（主显示器）" : "");
                var box = new CheckBox { Content = label, IsChecked = !M.Settings.NoSidebarMonitors.Contains(m.Device), Margin = new Thickness(12, 2, 0, 2), ToolTip = m.Device };
                monitorBoxes[m.Device] = box;
                root.Children.Add(box);
            }
        }
        tileNew.IsChecked = M.Settings.TileNewWorkspaces;
        tileNew.Margin = new Thickness(0, 6, 0, 0);
        root.Children.Add(tileNew);

        root.Children.Add(Header("热键（点击输入框后按下组合键；Backspace 清除）"));
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(170) });
        var row = 0;
        foreach (var a in HotKeyMap.All)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var label = new TextBlock { Text = a.Label, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 2, 8, 2) };
            var box = new TextBox { Text = HotKeyMap.ChordFor(M.Settings, a), IsReadOnly = true, Margin = new Thickness(0, 2, 0, 2) };
            if (shell.FailedHotKeys.Contains(a.Id)) { box.Foreground = Brushes.Firebrick; box.ToolTip = "被其他程序占用，未生效"; }
            box.PreviewKeyDown += (_, e) => Capture(box, e);
            Grid.SetRow(label, row); Grid.SetRow(box, row); Grid.SetColumn(box, 1);
            grid.Children.Add(label); grid.Children.Add(box);
            chordBoxes[a.Id] = box;
            row++;
        }
        var reset = new Button { Content = "恢复默认热键", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0), Padding = new Thickness(8, 2, 8, 2) };
        reset.Click += (_, _) => { foreach (var a in HotKeyMap.All) chordBoxes[a.Id].Text = a.Default; };
        root.Children.Add(new ScrollViewer { Content = grid, Height = 280, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        root.Children.Add(reset);

        root.Children.Add(Header("切走时最小化（而不是隐藏）的应用"));
        root.Children.Add(new TextBlock
        {
            Text = "有些程序被隐藏后会关闭或出错。窗口在隐藏后几秒内自己关闭时，TabStack 会自动把它的应用加进来。",
            TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gray, Margin = new Thickness(0, 0, 0, 4),
        });
        foreach (var app in M.Settings.MinimizeApps) minimizeList.Items.Add(app);
        root.Children.Add(minimizeList);
        var appRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0) };
        var running = new ComboBox { Width = 300, IsEditable = false };
        foreach (var g in shell.Platform.EnumerateWindows().GroupBy(w => w.AppID).OrderBy(g => g.First().AppName))
            running.Items.Add(new ComboBoxItem { Content = g.First().AppName, Tag = g.Key, ToolTip = g.Key });
        var add = new Button { Content = "添加", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(8, 0, 8, 0) };
        add.Click += (_, _) =>
        {
            if (running.SelectedItem is ComboBoxItem { Tag: string id } && !minimizeList.Items.Contains(id)) minimizeList.Items.Add(id);
        };
        var remove = new Button { Content = "移除所选", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(8, 0, 8, 0) };
        remove.Click += (_, _) => { if (minimizeList.SelectedItem is { } s) minimizeList.Items.Remove(s); };
        appRow.Children.Add(running);
        appRow.Children.Add(add);
        appRow.Children.Add(remove);
        root.Children.Add(appRow);

        root.Children.Add(status);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        var ok = new Button { Content = "保存", IsDefault = true, MinWidth = 80, Margin = new Thickness(0, 0, 8, 0) };
        ok.Click += (_, _) => Apply();
        var cancel = new Button { Content = "关闭", IsCancel = true, MinWidth = 80 };
        cancel.Click += (_, _) => Close();
        buttons.Children.Add(ok);
        buttons.Children.Add(cancel);
        root.Children.Add(buttons);

        Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    static TextBlock Header(string text) => new()
    {
        Text = text, FontWeight = FontWeights.SemiBold, FontSize = 14, Margin = new Thickness(0, 12, 0, 6),
    };

    static void Capture(TextBox box, KeyEventArgs e)
    {
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.Back or Key.Delete && Keyboard.Modifiers == ModifierKeys.None) { box.Text = ""; return; }
        var win = Keyboard.IsKeyDown(Key.LWin) || Keyboard.IsKeyDown(Key.RWin);
        if (HotKeyMap.Format(Keyboard.Modifiers, key, win) is { } chord) box.Text = chord;
    }

    void Apply()
    {
        if (!int.TryParse(limitBox.Text, out var limit) || limit is < 1 or > 30)
        {
            status.Text = "工作区数量请填 1 到 30。";
            return;
        }
        if (monitorBoxes.Count > 0 && monitorBoxes.Values.All(b => b.IsChecked != true))
        {
            status.Foreground = Brushes.Firebrick;
            status.Text = "至少要在一块显示器上显示侧边栏。";
            return;
        }
        var noSidebar = monitorBoxes.Where(kv => kv.Value.IsChecked != true).Select(kv => kv.Key).ToList();
        // Monitors not plugged in now keep their setting.
        noSidebar.AddRange(M.Settings.NoSidebarMonitors.Where(d => !monitorBoxes.ContainsKey(d)));
        var monitorsChanged = !noSidebar.ToHashSet().SetEquals(M.Settings.NoSidebarMonitors);
        M.UpdateSettings(s =>
        {
            s.NoSidebarMonitors = noSidebar;
            s.TileNewWorkspaces = tileNew.IsChecked == true;
            s.MinimizeApps = minimizeList.Items.Cast<string>().ToList();
            s.HotKeys = HotKeyMap.All
                .Where(a => chordBoxes[a.Id].Text != a.Default)
                .ToDictionary(a => a.Id, a => chordBoxes[a.Id].Text);
        });
        M.ActiveLimit = limit;
        shell.RegisterHotKeys();
        if (monitorsChanged)
        {
            M.AssignDisplays();
            shell.SyncSidebars();
        }

        foreach (var a in HotKeyMap.All)
        {
            var failed = shell.FailedHotKeys.Contains(a.Id);
            chordBoxes[a.Id].Foreground = failed ? Brushes.Firebrick : SystemColors.ControlTextBrush;
            chordBoxes[a.Id].ToolTip = failed ? "被其他程序占用，未生效" : null;
        }
        status.Foreground = shell.FailedHotKeys.Count > 0 ? Brushes.Firebrick : Brushes.SeaGreen;
        status.Text = shell.FailedHotKeys.Count > 0
            ? $"已保存。{shell.FailedHotKeys.Count} 个热键被其他程序占用（红色），换一个组合再保存。"
            : "已保存，所有热键都已生效。";
    }
}
