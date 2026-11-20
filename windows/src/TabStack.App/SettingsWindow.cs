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
    readonly CheckBox startAtLogin = new() { Content = "Start TabStack when I sign in to Windows", Margin = new Thickness(0, 0, 0, 4) };
    readonly Dictionary<string, CheckBox> monitorBoxes = new();
    readonly TextBlock status = new() { Foreground = Brushes.Firebrick, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };

    WorkspaceManager M => shell.Manager;

    public SettingsWindow(AppShell shell)
    {
        this.shell = shell;
        Title = "TabStack Settings";
        Width = 520;
        SizeToContent = SizeToContent.Height;
        MaxHeight = SystemParameters.WorkArea.Height - 40;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var root = new StackPanel { Margin = new Thickness(16) };

        root.Children.Add(Header("General"));
        startAtLogin.IsChecked = M.Settings.StartAtLogin;
        root.Children.Add(startAtLogin);

        root.Children.Add(Header("Sidebar"));
        var limitRow = new StackPanel { Orientation = Orientation.Horizontal };
        limitRow.Children.Add(new TextBlock { Text = "Workspaces shown in the sidebar: ", VerticalAlignment = VerticalAlignment.Center });
        limitBox.Text = M.ActiveLimit.ToString();
        limitRow.Children.Add(limitBox);
        root.Children.Add(limitRow);
        var monitors = shell.Platform.Monitors();
        if (monitors.Count > 1)
        {
            root.Children.Add(new TextBlock { Text = "Show a sidebar on these displays (each shows its own workspace):", Margin = new Thickness(0, 8, 0, 2) });
            foreach (var m in monitors.OrderBy(m => m.Bounds.X))
            {
                var label = $"{m.Name ?? "Display"}  {m.Bounds.W}×{m.Bounds.H}" + (m.Primary ? " (main)" : "");
                var box = new CheckBox { Content = label, IsChecked = !M.Settings.NoSidebarMonitors.Contains(m.Device), Margin = new Thickness(12, 2, 0, 2), ToolTip = m.Device };
                monitorBoxes[m.Device] = box;
                root.Children.Add(box);
            }
        }

        root.Children.Add(Header("Hotkeys (click a box, then press the keys; Backspace clears)"));
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(170) });
        var row = 0;
        foreach (var a in HotKeyMap.All)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var label = new TextBlock { Text = a.Label, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 2, 8, 2) };
            var box = new TextBox { Text = HotKeyMap.ChordFor(M.Settings, a), IsReadOnly = true, Margin = new Thickness(0, 2, 0, 2) };
            if (shell.FailedHotKeys.Contains(a.Id)) { box.Foreground = Brushes.Firebrick; box.ToolTip = "Taken by another app; not active"; }
            box.PreviewKeyDown += (_, e) => Capture(box, e);
            Grid.SetRow(label, row); Grid.SetRow(box, row); Grid.SetColumn(box, 1);
            grid.Children.Add(label); grid.Children.Add(box);
            chordBoxes[a.Id] = box;
            row++;
        }
        var reset = new Button { Content = "Restore Default Hotkeys", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0), Padding = new Thickness(8, 2, 8, 2) };
        reset.Click += (_, _) => { foreach (var a in HotKeyMap.All) chordBoxes[a.Id].Text = a.Default; };
        root.Children.Add(new ScrollViewer { Content = grid, Height = 280, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        root.Children.Add(reset);

        root.Children.Add(Header("Apps minimized instead of hidden"));
        root.Children.Add(new TextBlock
        {
            Text = "Some apps close or misbehave when their window is hidden. When a window closes itself within seconds of being hidden, TabStack adds its app here.",
            TextWrapping = TextWrapping.Wrap, Foreground = Brushes.Gray, Margin = new Thickness(0, 0, 0, 4),
        });
        foreach (var app in M.Settings.MinimizeApps) minimizeList.Items.Add(app);
        root.Children.Add(minimizeList);
        var appRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0) };
        var running = new ComboBox { Width = 300, IsEditable = false };
        foreach (var g in shell.Platform.EnumerateWindows().GroupBy(w => w.AppID).OrderBy(g => g.First().AppName))
            running.Items.Add(new ComboBoxItem { Content = g.First().AppName, Tag = g.Key, ToolTip = g.Key });
        var add = new Button { Content = "Add", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(8, 0, 8, 0) };
        add.Click += (_, _) =>
        {
            if (running.SelectedItem is ComboBoxItem { Tag: string id } && !minimizeList.Items.Contains(id)) minimizeList.Items.Add(id);
        };
        var remove = new Button { Content = "Remove", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(8, 0, 8, 0) };
        remove.Click += (_, _) => { if (minimizeList.SelectedItem is { } s) minimizeList.Items.Remove(s); };
        appRow.Children.Add(running);
        appRow.Children.Add(add);
        appRow.Children.Add(remove);
        root.Children.Add(appRow);

        root.Children.Add(status);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        var ok = new Button { Content = "Save", IsDefault = true, MinWidth = 80, Margin = new Thickness(0, 0, 8, 0) };
        ok.Click += (_, _) => Apply();
        var cancel = new Button { Content = "Close", IsCancel = true, MinWidth = 80 };
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
            status.Text = "Enter a number of workspaces from 1 to 30.";
            return;
        }
        if (monitorBoxes.Count > 0 && monitorBoxes.Values.All(b => b.IsChecked != true))
        {
            status.Foreground = Brushes.Firebrick;
            status.Text = "Show the sidebar on at least one display.";
            return;
        }
        var noSidebar = monitorBoxes.Where(kv => kv.Value.IsChecked != true).Select(kv => kv.Key).ToList();
        // Monitors not plugged in now keep their setting.
        noSidebar.AddRange(M.Settings.NoSidebarMonitors.Where(d => !monitorBoxes.ContainsKey(d)));
        var monitorsChanged = !noSidebar.ToHashSet().SetEquals(M.Settings.NoSidebarMonitors);
        M.UpdateSettings(s =>
        {
            s.NoSidebarMonitors = noSidebar;
            s.MinimizeApps = minimizeList.Items.Cast<string>().ToList();
            s.StartAtLogin = startAtLogin.IsChecked == true;
            s.HotKeys = HotKeyMap.All
                .Where(a => chordBoxes[a.Id].Text != a.Default)
                .ToDictionary(a => a.Id, a => chordBoxes[a.Id].Text);
        });
        M.ActiveLimit = limit;
        Autostart.Apply(M.Settings.StartAtLogin);
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
            chordBoxes[a.Id].ToolTip = failed ? "Taken by another app; not active" : null;
        }
        status.Foreground = shell.FailedHotKeys.Count > 0 ? Brushes.Firebrick : Brushes.SeaGreen;
        status.Text = shell.FailedHotKeys.Count > 0
            ? $"Saved. {shell.FailedHotKeys.Count} hotkey(s) are taken by other apps (red): pick other keys and save again."
            : "Saved. All hotkeys are active.";
    }
}
