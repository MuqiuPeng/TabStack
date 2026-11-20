using System.IO;
using System.Media;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using TabStack.Core;

namespace TabStack.App;

/// <summary>Ctrl+Alt+T (Mac ⌃⌥T): the TicketDeck tickets of the current workspace's projects
/// (or of every project), in a floating panel like the pickers. The first one of the day opens
/// on 今日计划 (today's plan); Tab cycles this workspace → all projects → 今日计划 → 提议执行.
/// Enter goes to the ticket's Claude session (switching to the project's workspace first),
/// Ctrl+D marks a ticket done, Ctrl+R sends it back to to do, Ctrl+Backspace drops it.</summary>
sealed class TicketPanel : Window
{
    static readonly Brush Back = Frozen(Color.FromRgb(0x26, 0x27, 0x2B));
    static readonly Brush Line = Frozen(Color.FromRgb(0x3A, 0x3B, 0x40));
    static readonly Brush Soft = Frozen(Color.FromRgb(0x30, 0x31, 0x36));
    static readonly Brush Fore = Frozen(Color.FromRgb(0xE6, 0xE6, 0xE6));
    static readonly Brush Dim = Frozen(Color.FromRgb(0x9A, 0x9B, 0xA0));
    static readonly Brush Pick = Frozen(Color.FromArgb(0x40, 0x4F, 0x7D, 0xF3));
    static readonly Color Blue = Color.FromRgb(0x4F, 0x9D, 0xF7), Orange = Color.FromRgb(0xF0, 0x9A, 0x37),
        Green = Color.FromRgb(0x4C, 0xC3, 0x6A), Red = Color.FromRgb(0xF0, 0x5A, 0x50), Gray = Color.FromRgb(0x9A, 0x9B, 0xA0),
        Purple = Color.FromRgb(0xB3, 0x7F, 0xEB), Teal = Color.FromRgb(0x3F, 0xC6, 0xC2), Yellow = Color.FromRgb(0xE6, 0xC3, 0x3D);

    static readonly string[] Order = ["doing", "review", "todo", "done"];
    static readonly Dictionary<string, string> Names = new() { ["doing"] = "Doing", ["review"] = "Review", ["todo"] = "To do", ["done"] = "Done" };
    static readonly Dictionary<string, (string, Color)> Kinds = new()
    {
        ["review"] = ("待验收", Orange), ["decision"] = ("待决策", Purple), ["action"] = ("需你执行", Purple), ["push"] = ("优先推进", Blue),
    };

    static string PlanShownFile => Path.Combine(Store.DefaultDirectory, "ticket-plan-shown.txt");

    readonly AppShell shell;
    readonly Workspace ws;
    readonly TextBox search;
    readonly TextBlock hint;
    readonly TextBlock heading = new() { FontSize = 18, Foreground = Fore, VerticalAlignment = VerticalAlignment.Center };
    readonly StackPanel buttons = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    readonly Border body = new();
    readonly TextBlock footerHint = new() { Foreground = Dim, FontSize = 10.5 };
    readonly TextBlock footerCount = new() { Foreground = Dim, FontSize = 10.5 };
    readonly DispatcherTimer refresh = new() { Interval = TimeSpan.FromSeconds(2) };
    readonly HashSet<string> openFolds = new();
    FrameworkElement? selectedRow;
    bool closing;

    List<TicketProject> projects = new();
    string raw = "";
    string? error;
    bool loaded, all, showReport, showProposals;
    string? selectedKey;
    List<string> dates = new();
    int reportIndex, focusIndex, proposalIndex;
    DailyReport? report, proposals;
    DateTime reportStamp;
    ProposeJob? job;
    string? startError;

    WorkspaceManager M => shell.Manager;

    public TicketPanel(AppShell shell, MonitorInfo? display)
    {
        this.shell = shell;
        ws = shell.Manager.Current;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Width = 820;
        Height = 500;
        Background = Back;
        BorderBrush = Line;
        BorderThickness = new Thickness(1);
        Title = "TabStack Tickets";

        hint = new TextBlock { Text = "Search tickets", Foreground = Dim, FontSize = 18, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(2, 0, 0, 0), IsHitTestVisible = false };
        search = new TextBox
        {
            FontSize = 18, Foreground = Fore, Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            CaretBrush = Fore, VerticalAlignment = VerticalAlignment.Center,
        };
        search.TextChanged += (_, _) =>
        {
            hint.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            Clamp();
            Render();
        };

        var left = new Grid { Margin = new Thickness(0, 0, 10, 0) };
        left.Children.Add(hint);
        left.Children.Add(search);
        left.Children.Add(heading);
        var header = new DockPanel { Height = 50, Margin = new Thickness(16, 0, 12, 0) };
        DockPanel.SetDock(buttons, System.Windows.Controls.Dock.Right);
        header.Children.Add(buttons);
        header.Children.Add(left);

        var footer = new DockPanel { Height = 26, Margin = new Thickness(14, 0, 14, 0) };
        footerHint.VerticalAlignment = footerCount.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(footerCount, System.Windows.Controls.Dock.Right);
        footer.Children.Add(footerCount);
        footer.Children.Add(footerHint);

        var root = new DockPanel();
        Dock(root, header, System.Windows.Controls.Dock.Top);
        Dock(root, Rule(), System.Windows.Controls.Dock.Top);
        Dock(root, footer, System.Windows.Controls.Dock.Bottom);
        Dock(root, Rule(), System.Windows.Controls.Dock.Bottom);
        root.Children.Add(body);
        Content = root;

        if (display is not null)
        {
            var k = 96.0 / Math.Max(display.Dpi, 96);
            Left = display.WorkArea.X * k + (display.WorkArea.W * k - Width) / 2;
            Top = display.WorkArea.Y * k + display.WorkArea.H * k * 0.16;
        }
        else WindowStartupLocation = WindowStartupLocation.CenterScreen;

        // The first Ctrl+Alt+T of the day opens on today's plan.
        LoadReports();
        LoadProposals();
        if (dates.FirstOrDefault() == DailyReport.Today && ReadPlanShown() != DailyReport.Today)
        {
            WritePlanShown(DailyReport.Today);
            reportIndex = 0;
            ReadReport();
            showReport = true;
        }

        PreviewKeyDown += OnKey;
        Deactivated += (_, _) => Dismiss();
        Closed += (_, _) => refresh.Stop();
        Loaded += (_, _) => { Activate(); Keyboard.Focus(search); };
        // Agents edit tickets while you look; follow along.
        refresh.Tick += (_, _) =>
        {
            _ = Reload();
            if (showReport) RefreshReport();
            if (showProposals) { LoadProposals(); Render(); }
        };
        refresh.Start();
        Render();
        _ = Reload();
    }

    static void Dock(DockPanel panel, UIElement e, System.Windows.Controls.Dock side) { DockPanel.SetDock(e, side); panel.Children.Add(e); }

    public void Dismiss()
    {
        if (closing) return;
        closing = true;
        Close();
    }

    static string? ReadPlanShown() { try { return File.ReadAllText(PlanShownFile).Trim(); } catch { return null; } }
    static void WritePlanShown(string day) { try { File.WriteAllText(PlanShownFile, day); } catch { } }

    // ───────────────────────── Data ─────────────────────────

    async Task Reload()
    {
        var (list, json, err) = await TicketDeck.State();
        if (closing) return;
        if (list is null)
        {
            if (error == err) return;
            error = err;
            Render();
            return;
        }
        if (json == raw && error is null && loaded) return;
        raw = json;
        error = null;
        projects = list;
        // A workspace with no tickets of its own opens on every project.
        if (!loaded) all = Scoped(false).Count == 0;
        loaded = true;
        Clamp();
        Render();
    }

    async void SetStatus(string status)
    {
        if (Selected is not { } t) { SystemSounds.Beep.Play(); return; }
        var (ok, _, _) = await TicketDeck.Run(["set", t.Id, "status=" + status], t.ProjectPath);
        if (!ok) SystemSounds.Beep.Play();
        await Reload();
    }

    async void ToggleCheck(TicketItem t, int index, bool on)
    {
        var (ok, _, _) = await TicketDeck.Run(["check", t.Id, (index + 1).ToString(), on ? "on" : "off"], t.ProjectPath);
        if (!ok) SystemSounds.Beep.Play();
        await Reload();
    }

    List<TicketProject> Scoped(bool every) => every ? projects : projects.Where(p => TicketScope.Holds(ws, p.Path)).ToList();

    List<(string Status, List<TicketItem> Tickets)> Groups()
    {
        var q = search.Text.Trim();
        bool Has(string s) => s.Contains(q, StringComparison.CurrentCultureIgnoreCase);
        var tickets = Scoped(all).SelectMany(p => p.Tickets)
            .Where(t => q.Length == 0 || Has(t.Title) || Has(t.Id) || Has(t.ProjectName) || t.Labels.Any(Has)).ToList();
        return Order.Select(s => (s, tickets.Where(t => t.Status == s).ToList())).Where(g => g.Item2.Count > 0).ToList();
    }

    List<TicketItem> Flat() => Groups().SelectMany(g => g.Tickets).ToList();

    TicketItem? Selected => Flat().Find(t => t.Key == selectedKey);

    void Clamp()
    {
        var list = Flat();
        if (!list.Exists(t => t.Key == selectedKey)) selectedKey = list.FirstOrDefault()?.Key;
    }

    void Move(int d)
    {
        var list = Flat();
        if (list.Count == 0) return;
        var i = list.FindIndex(t => t.Key == selectedKey);
        if (i < 0) i = d > 0 ? -1 : list.Count;
        selectedKey = list[Math.Clamp(i + d, 0, list.Count - 1)].Key;
        Render();
    }

    string? LiveStatus(string root, string id) =>
        projects.Find(p => SamePath(p.Path, root))?.Tickets.Find(t => t.Id == id)?.Status;

    static bool SamePath(string a, string b) =>
        string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);

    void OpenTicket(string root, string id)
    {
        showReport = showProposals = false;
        all = true;
        selectedKey = projects.Find(p => SamePath(p.Path, root)) is { } p ? p.Path + "#" + id : root + "#" + id;
        Render();
    }

    // 今日计划

    void LoadReports()
    {
        var shown = reportIndex < dates.Count ? dates[reportIndex] : null;
        dates = DailyReport.Dates();
        reportIndex = shown is not null && dates.IndexOf(shown) is var i and >= 0 ? i : 0;
        ReadReport();
    }

    void ReadReport()
    {
        if (reportIndex >= dates.Count) { report = null; return; }
        var file = Path.Combine(TicketDeck.ReportsDir, dates[reportIndex] + ".json");
        reportStamp = File.Exists(file) ? File.GetLastWriteTimeUtc(file) : default;
        report = DailyReport.Load(dates[reportIndex]);
        focusIndex = 0;
    }

    /// <summary>The shown report is re-read when its file changed (proposals written).</summary>
    void RefreshReport()
    {
        if (reportIndex >= dates.Count) { LoadReports(); Render(); return; }
        var file = Path.Combine(TicketDeck.ReportsDir, dates[reportIndex] + ".json");
        if ((File.Exists(file) ? File.GetLastWriteTimeUtc(file) : default) == reportStamp) return;
        var keep = focusIndex;
        ReadReport();
        focusIndex = Math.Min(keep, Math.Max(0, (report?.FocusList?.Count ?? 1) - 1));
        Render();
    }

    void StepReport(int d)
    {
        if (dates.Count == 0) return;
        reportIndex = Math.Clamp(reportIndex + d, 0, dates.Count - 1);
        ReadReport();
        Render();
    }

    DailyReport.Focus? CurrentFocus => report?.FocusList?.ElementAtOrDefault(focusIndex);

    /// <summary>A focus item's main action: accept it if it waits for review, else go to its session.</summary>
    async void FocusAction(DailyReport.Focus f)
    {
        if (f.Kind == "review")
        {
            var (ok, _, _) = await TicketDeck.Run(["set", f.Id, "status=done"], f.Root);
            if (!ok) SystemSounds.Beep.Play();
            await Reload();
            return;
        }
        OpenTicket(f.Root, f.Id);
        Jump();
    }

    // 提议执行

    void LoadProposals()
    {
        var latest = DailyReport.Dates().FirstOrDefault();
        proposals = latest is null ? null : DailyReport.Load(latest);
        job = latest is null ? null : ProposeJob.Load(latest);
        var n = Actionable().Count;
        if (proposalIndex >= n) proposalIndex = Math.Max(0, n - 1);
    }

    /// <summary>Open first, then started; dismissed ones are folded away.</summary>
    List<DailyReport.Proposal> Actionable()
    {
        var list = proposals?.Proposals ?? [];
        return list.Where(p => p.Status is null).Concat(list.Where(p => p.Status == "started")).ToList();
    }

    int OpenProposalCount => proposals?.Date == DailyReport.Today ? (proposals.Proposals ?? []).Count(p => p.Status is null) : 0;

    /// <summary>执行 opens a new Claude Code session in the project with the proposal's
    /// instructions filled in (the user sends them); 忽略 hides it. TicketDeck keeps what the
    /// user did in the report, so the web board shows the same.</summary>
    async void ProposalAction(DailyReport.Proposal p, bool run)
    {
        if (proposals?.Date is not { } date) return;
        if (run)
        {
            Dismiss();
            ClaudeLinks.NewSession(SessionPrompt(p, date), p.Root);
        }
        var (ok, _, _) = await TicketDeck.Run(["report", "proposal", p.Id, run ? "started" : "dismissed", "--date", date]);
        if (!ok) SystemSounds.Beep.Play();
        if (closing) return;
        LoadProposals();
        Render();
    }

    async void RestoreProposal(DailyReport.Proposal p)
    {
        if (proposals?.Date is not { } date) return;
        await TicketDeck.Run(["report", "proposal", p.Id, "open", "--date", date]);
        LoadProposals();
        Render();
    }

    /// <summary>What the new session gets: where the task comes from, filing itself under the
    /// user's sidebar group, then the proposal's instructions. The web board sends the same.</summary>
    static string SessionPrompt(DailyReport.Proposal p, string date)
    {
        var tickets = string.Join("、", p.Tickets ?? []);
        return $"（来自 TicketDeck 今日计划 {date} 的提议 {p.Id}：{p.Title}{(tickets.Length == 0 ? "" : "，涉及 " + tickets)}）\n\n"
            + "开始前先整理侧边栏：调用 `mcp__ccd_sidebar__list_groups`，如果有名字和项目「" + p.Project + "」相同（不区分大小写）的分组，"
            + "就用 `mcp__ccd_sidebar__move_sessions`（session_ids: [\"self\"]）把这个会话移进去；没有就跳过，不要新建分组。\n\n" + p.Prompt;
    }

    /// <summary>Writes the proposals now (the morning task does it every day): TicketDeck runs
    /// Claude Code headless in the background; the panel follows its state file.</summary>
    async void Generate()
    {
        if ((proposals?.Date ?? dates.FirstOrDefault()) is not { } date) { SystemSounds.Beep.Play(); return; }
        startError = null;
        var (ok, _, err) = await TicketDeck.Run(["report", "propose", "--background", "--date", date]);
        if (!ok) startError = err;
        LoadProposals();
        Render();
    }

    // ───────────────────────── Going to the work ─────────────────────────

    /// <summary>To the workspace that holds the ticket's project, with Claude on the ticket's session.</summary>
    void Jump()
    {
        if (Selected is not { } t) { SystemSounds.Beep.Play(); return; }
        bool Holds(Workspace w) => TicketScope.Holds(w, t.ProjectPath);
        var target = Holds(M.Current) ? M.Current : M.Workspaces.FirstOrDefault(Holds);
        Dismiss();
        if (target is null)
        {
            if (t.HasClaudeSession) ClaudeLinks.Open(t.Session!);
            else SystemSounds.Beep.Play();
            return;
        }
        if (target.Id != M.Current.Id) M.SwitchWorkspace(target.Id);
        if (!t.HasClaudeSession) return;
        if (M.Current.Tabs.FirstOrDefault(ClaudeLinks.IsClaude) is { } claude) shell.OpenTab(claude);
        ClaudeLinks.Open(t.Session!);
    }

    // ───────────────────────── Keys ─────────────────────────

    void OnKey(object sender, KeyEventArgs e)
    {
        var ctrl = Keyboard.Modifiers == ModifierKeys.Control;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        switch (key)
        {
            case Key.Escape: Dismiss(); break;
            case Key.Enter when showProposals:
                if (Actionable().ElementAtOrDefault(proposalIndex) is { } p) ProposalAction(p, true); else SystemSounds.Beep.Play();
                break;
            case Key.Enter when showReport:
                if (CurrentFocus is { } f) FocusAction(f); else SystemSounds.Beep.Play();
                break;
            case Key.Enter: Jump(); break;
            case Key.Down when showProposals: proposalIndex = Math.Min(proposalIndex + 1, Math.Max(0, Actionable().Count - 1)); Render(); break;
            case Key.Up when showProposals: proposalIndex = Math.Max(proposalIndex - 1, 0); Render(); break;
            case Key.Down when showReport: focusIndex = Math.Min(focusIndex + 1, Math.Max(0, (report?.FocusList?.Count ?? 1) - 1)); Render(); break;
            case Key.Up when showReport: focusIndex = Math.Max(focusIndex - 1, 0); Render(); break;
            case Key.Down: Move(1); break;
            case Key.Up: Move(-1); break;
            case Key.Tab: Cycle(); break;
            case Key.Left when showReport: StepReport(1); break;   // older
            case Key.Right when showReport: StepReport(-1); break; // newer
            case Key.D when ctrl && !showReport && !showProposals: SetStatus("done"); break;
            case Key.R when ctrl && !showReport && !showProposals: SetStatus("todo"); break;
            // Ctrl+Backspace also deletes a word of the search, so it drops only while that is empty.
            case Key.Back when ctrl && search.Text.Length == 0 && !showReport && !showProposals: SetStatus("dropped"); break;
            default: return;
        }
        e.Handled = true;
    }

    /// <summary>Tab: this workspace → all projects → 今日计划 → 提议执行 → this workspace.</summary>
    void Cycle()
    {
        if (showProposals) { showProposals = false; all = false; }
        else if (showReport) { showReport = false; showProposals = true; LoadProposals(); }
        else if (all) { showReport = true; LoadReports(); }
        else all = true;
        Clamp();
        Render();
        if (!showReport && !showProposals) Keyboard.Focus(search);
    }

    // ───────────────────────── Drawing ─────────────────────────

    void Render()
    {
        var mode = showProposals ? "proposals" : showReport ? "report" : "list";
        search.Visibility = hint.Visibility = mode == "list" ? Visibility.Visible : Visibility.Collapsed;
        if (mode == "list") hint.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        heading.Visibility = mode == "list" ? Visibility.Collapsed : Visibility.Visible;
        heading.Text = showProposals ? "✦ 提议执行" : "☀ 今日计划";
        heading.Foreground = new SolidColorBrush(showProposals ? Teal : Orange);

        buttons.Children.Clear();
        buttons.Children.Add(Toggle("☀ 今日计划", showReport, Orange, () =>
        {
            showProposals = false;
            showReport = !showReport;
            if (showReport) LoadReports();
            Render();
        }));
        var count = OpenProposalCount;
        buttons.Children.Add(Toggle(count > 0 ? $"✦ 提议执行 {count}" : "✦ 提议执行", showProposals, Teal, () =>
        {
            showReport = false;
            showProposals = !showProposals;
            if (showProposals) LoadProposals();
            Render();
        }));
        var scope = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 0, 0, 0), Opacity = mode == "list" ? 1 : 0.5 };
        scope.Children.Add(Toggle(ws.Name.Length > 0 ? ws.Name : "This workspace", !all, Blue, () => SetScope(false), margin: 0));
        scope.Children.Add(Toggle("All projects", all, Blue, () => SetScope(true), margin: 0));
        buttons.Children.Add(scope);

        selectedRow = null;
        body.Child = error is not null ? Center(error) : mode switch
        {
            "proposals" => ProposalsView(),
            "report" => ReportView(),
            _ => ListView(),
        };

        footerHint.Text = showProposals ? "↑↓ 选择   ↩ 执行（开新会话）   Tab 回到任务列表   Esc 关闭"
            : showReport ? "↑↓ 选择   ↩ 执行   ←→ 前一天 / 后一天   Tab 提议执行   Esc 关闭"
            : "↑↓ select   ↩ open session   Ctrl+D done   Ctrl+R to do   Ctrl+⌫ drop   Tab scope   Esc close";
        footerCount.Text = $"{Scoped(all).SelectMany(p => p.Tickets).Count(t => t.Status != "done")} open";
        if (selectedRow is not null) Dispatcher.BeginInvoke(() => selectedRow?.BringIntoView(), DispatcherPriority.Loaded);
    }

    void SetScope(bool every)
    {
        showReport = showProposals = false;
        all = every;
        Clamp();
        Render();
        Keyboard.Focus(search);
    }

    FrameworkElement ListView()
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(340) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());

        var list = new StackPanel { Margin = new Thickness(8) };
        var groups = Groups();
        foreach (var (status, tickets) in groups)
        {
            var head = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 8, 8, 2) };
            head.Children.Add(Dot(StatusColor(status), 7));
            head.Children.Add(Txt(Names.GetValueOrDefault(status, status), 10, new SolidColorBrush(StatusColor(status)), bold: true, margin: new Thickness(5, 0, 5, 0)));
            head.Children.Add(Txt(tickets.Count.ToString(), 10, Dim, bold: true));
            list.Children.Add(head);
            foreach (var t in tickets) list.Children.Add(Row(t));
        }
        if (groups.Count == 0)
            list.Children.Add(Txt(projects.Count == 0 ? (loaded ? "No tickets yet" : "Loading…") : all ? "No matching tickets" : "No tickets for this workspace's projects (Tab for all)",
                12, Dim, margin: new Thickness(0, 40, 0, 0), center: true));
        var scroll = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        grid.Children.Add(scroll);
        var sep = new Border { Background = Line };
        Grid.SetColumn(sep, 1);
        grid.Children.Add(sep);
        var detail = Detail();
        Grid.SetColumn(detail, 2);
        grid.Children.Add(detail);
        return grid;
    }

    FrameworkElement Row(TicketItem t)
    {
        var selected = t.Key == selectedKey;
        var row = new DockPanel { Height = 30, Margin = new Thickness(0, 0, 0, 1) };
        var bar = new Border { Width = 3, Height = 16, CornerRadius = new CornerRadius(1.5), Background = new SolidColorBrush(StatusColor(t.Status)), Margin = new Thickness(8, 0, 8, 0) };
        DockPanel.SetDock(bar, System.Windows.Controls.Dock.Left);
        row.Children.Add(bar);
        var id = Txt(t.Id, 11, Dim, mono: true, margin: new Thickness(0, 0, 8, 0));
        DockPanel.SetDock(id, System.Windows.Controls.Dock.Left);
        row.Children.Add(id);
        var right = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(4, 0, 8, 0) };
        if (t.Priority is "P0" or "P1") right.Children.Add(Txt(t.Priority, 9, new SolidColorBrush(PriorityColor(t.Priority)), bold: true, margin: new Thickness(0, 0, 6, 0)));
        if (all) right.Children.Add(Chip(t.ProjectName, Dim));
        if (t.Session is not null && t.Status == "doing") right.Children.Add(Txt("●", 9, new SolidColorBrush(Blue), margin: new Thickness(6, 0, 0, 0)));
        DockPanel.SetDock(right, System.Windows.Controls.Dock.Right);
        row.Children.Add(right);
        var title = Txt(t.Title, 12.5, t.Status == "done" ? Dim : Fore);
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        row.Children.Add(title);

        var box = new Border { Child = row, CornerRadius = new CornerRadius(6), Background = selected ? Pick : Brushes.Transparent, Cursor = Cursors.Hand };
        box.MouseLeftButtonDown += (_, e) =>
        {
            selectedKey = t.Key;
            if (e.ClickCount == 2) Jump(); else Render();
            e.Handled = true;
        };
        if (selected) selectedRow = box;
        return box;
    }

    FrameworkElement Detail()
    {
        if (Selected is not { } t) return Center("Select a ticket");
        var s = new StackPanel { Margin = new Thickness(16) };
        var top = new DockPanel();
        var chips = new StackPanel { Orientation = Orientation.Horizontal };
        chips.Children.Add(StatusChip(t.Status));
        chips.Children.Add(Chip(t.Priority, Fore));
        chips.Children.Add(Chip(t.Type, Fore));
        DockPanel.SetDock(chips, System.Windows.Controls.Dock.Right);
        top.Children.Add(chips);
        top.Children.Add(Txt($"{t.ProjectName} · {t.Id}", 11, Dim, mono: true));
        s.Children.Add(top);
        s.Children.Add(Txt(t.Title, 16, Fore, bold: true, wrap: true, margin: new Thickness(0, 10, 0, 0)));
        var tags = t.Labels.Select(l => "#" + l).Concat(t.DependsOn.Select(d => "needs " + d)).ToList();
        if (tags.Count > 0) s.Children.Add(Txt(string.Join("  ", tags), 11, Dim, margin: new Thickness(0, 6, 0, 0)));

        var actions = new WrapPanel { Margin = new Thickness(0, 10, 0, 10) };
        actions.Children.Add(Btn(t.HasClaudeSession ? "Open session ↩" : "Go to workspace ↩", Jump));
        if (t.Status is "review" or "doing" or "todo") actions.Children.Add(Btn("Done Ctrl+D", () => SetStatus("done")));
        if (t.Status != "todo") actions.Children.Add(Btn("Back to to do Ctrl+R", () => SetStatus("todo")));
        actions.Children.Add(Btn("Drop Ctrl+⌫", () => SetStatus("dropped")));
        if (t.Session is { } session)
            actions.Children.Add(Txt(session.StartsWith("local_") ? session[..Math.Min(14, session.Length)] : session, 10, Dim, mono: true, margin: new Thickness(6, 4, 0, 0)));
        s.Children.Add(actions);
        s.Children.Add(Rule());

        // The description, with checklist items as checkboxes that tick the item in the file.
        var (description, log) = t.Parts;
        var check = -1;
        var desc = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        foreach (var line in description.Split('\n'))
        {
            if (TicketItem.Check(line) is { } item)
            {
                var n = ++check;
                var box = new CheckBox { IsChecked = item.Done, Foreground = Fore, Margin = new Thickness(0, 2, 0, 2), Content = Txt(Inline(item.Text), 12.5, Fore, wrap: true) };
                box.Click += (_, _) => ToggleCheck(t, n, box.IsChecked == true);
                desc.Children.Add(box);
            }
            else if (line.StartsWith('#'))
                desc.Children.Add(Txt(line.TrimStart('#').Trim(), 12.5, Fore, bold: true, margin: new Thickness(0, 6, 0, 2)));
            else if (line.Trim().Length > 0)
                desc.Children.Add(Selectable(Inline(line), 12.5, Fore));
        }
        s.Children.Add(desc);
        if (log.Count > 0)
        {
            s.Children.Add(Txt("Log", 11, Dim, bold: true, margin: new Thickness(0, 10, 0, 2)));
            foreach (var l in log.TakeLast(8)) s.Children.Add(Txt(l, 11, Dim, wrap: true));
        }
        return new ScrollViewer { Content = s, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    FrameworkElement ReportView()
    {
        if (report is not { } r) return Center("还没有今日计划。每天早上 8 点自动生成\n（也可以运行 ticketdeck report --save）。");
        var s = new StackPanel { Margin = new Thickness(22, 16, 22, 16) };
        var top = new DockPanel();
        if (dates.Count > 1)
        {
            var page = Txt($"{reportIndex + 1} / {dates.Count}", 10, Dim);
            DockPanel.SetDock(page, System.Windows.Controls.Dock.Right);
            top.Children.Add(page);
        }
        var title = new StackPanel { Orientation = Orientation.Horizontal };
        title.Children.Add(Txt(r.DayTitle, 17, Fore, bold: true));
        title.Children.Add(Txt(r.StatusLine, 11.5, Dim, margin: new Thickness(10, 4, 0, 0)));
        top.Children.Add(title);
        s.Children.Add(top);
        if (!string.IsNullOrEmpty(r.Summary)) s.Children.Add(Txt(r.Summary, 13, Fore, wrap: true, margin: new Thickness(0, 10, 0, 0)));
        s.Children.Add(Txt("今日重点", 11, Dim, margin: new Thickness(0, 16, 0, 6)));
        var focus = r.FocusList ?? [];
        if (focus.Count == 0) s.Children.Add(Txt("今天没有需要你优先处理的任务。", 12.5, Dim));
        for (var i = 0; i < focus.Count; i++) s.Children.Add(FocusRow(focus[i], i));

        s.Children.Add(new Border { Height = 14 });
        s.Children.Add(Rule());
        s.Children.Add(Fold("昨日进展", r.ActivityList.Count, Green, () => r.ActivityList.Select(a =>
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 1, 0, 1) };
            line.Children.Add(new TextBlock { Text = a.Project, FontSize = 12, Foreground = Fore, Width = 160 });
            if (a.Done > 0) line.Children.Add(Chip($"完成 {a.Done}", new SolidColorBrush(Green)));
            if (a.Updated > 0) line.Children.Add(Chip($"更新 {a.Updated}", new SolidColorBrush(Blue)));
            if (a.Created > 0) line.Children.Add(Chip($"新增 {a.Created}", Dim));
            return (FrameworkElement)line;
        })));
        s.Children.Add(Fold("进行中", r.Doing.Count, Blue, () => r.Doing.Select(ItemRow)));
        s.Children.Add(Fold("待验收", r.Review.Count, Orange, () => r.Review.Select(ItemRow)));
        s.Children.Add(Fold("待决策与待执行", r.Totals.Decisions, Purple, () =>
        {
            var rows = r.Decisions.Select(ItemRow).ToList();
            if (r.Totals.Decisions > r.Decisions.Count)
                rows.Add(Txt($"另有 {r.Totals.Decisions - r.Decisions.Count} 项，在 All projects 里搜 decision 或 needs-user", 10.5, Dim));
            return rows;
        }));
        s.Children.Add(Fold("待纳入计划", r.Leftovers?.Count ?? 0, Yellow, () => (r.Leftovers ?? []).Select(l =>
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 1, 0, 1) };
            line.Children.Add(Txt(l.Project, 12, Dim, margin: new Thickness(0, 0, 6, 0)));
            line.Children.Add(Txt(l.Task, 12, Fore));
            return (FrameworkElement)line;
        })));
        return new ScrollViewer { Content = s, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    FrameworkElement FocusRow(DailyReport.Focus f, int n)
    {
        var (label, color) = Kinds.GetValueOrDefault(f.Kind, ("优先推进", Blue));
        var status = LiveStatus(f.Root, f.Id);
        var finished = status is "done" or "dropped";
        var selected = n == focusIndex;
        var row = new DockPanel();
        var num = Txt((n + 1).ToString(), 17, finished ? Dim : new SolidColorBrush(color), bold: true, margin: new Thickness(0, 0, 12, 0));
        num.Width = 28;
        DockPanel.SetDock(num, System.Windows.Controls.Dock.Left);
        row.Children.Add(num);
        if (!finished)
        {
            var act = Btn(f.Kind == "review" ? "验收通过" : f.Session?.StartsWith("local_") == true ? "继续会话" : "查看", () => FocusAction(f));
            act.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(act, System.Windows.Controls.Dock.Right);
            row.Children.Add(act);
        }
        var text = new StackPanel();
        var title = Txt($"{f.Project} · {f.Title}", 13, Fore, wrap: true);
        if (finished) title.TextDecorations = TextDecorations.Strikethrough;
        text.Children.Add(title);
        var meta = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 3, 0, 0) };
        meta.Children.Add(Chip(finished ? "已完成" : label, new SolidColorBrush(finished ? Green : color)));
        if (f.IdleDays >= 2 && !finished) meta.Children.Add(Txt($"{f.IdleDays} 天未推进", 10.5, Dim, margin: new Thickness(0, 0, 8, 0)));
        if (f.Reason is { } reason) meta.Children.Add(Txt(reason, 11, Fore));
        text.Children.Add(meta);
        row.Children.Add(text);
        var card = Card(row, selected, () => { focusIndex = n; Render(); });
        card.Opacity = finished ? 0.6 : 1;
        if (selected) selectedRow = card;
        return card;
    }

    FrameworkElement ItemRow(DailyReport.Item i)
    {
        var line = new DockPanel { Cursor = Cursors.Hand, Background = Brushes.Transparent, Margin = new Thickness(0, 1, 0, 1) };
        if (i.Stale == true)
        {
            var stale = Txt("停滞", 10.5, new SolidColorBrush(Red));
            DockPanel.SetDock(stale, System.Windows.Controls.Dock.Right);
            line.Children.Add(stale);
        }
        var p = Txt(i.Project, 12, Dim, margin: new Thickness(0, 0, 6, 0));
        DockPanel.SetDock(p, System.Windows.Controls.Dock.Left);
        line.Children.Add(p);
        var t = Txt(i.Title, 12, Fore);
        t.TextTrimming = TextTrimming.CharacterEllipsis;
        line.Children.Add(t);
        line.MouseLeftButtonDown += (_, e) => { OpenTicket(i.Root, i.Id); e.Handled = true; };
        return line;
    }

    FrameworkElement ProposalsView()
    {
        if (proposals is not { } r) return Center("还没有今日计划。每天早上 8 点自动生成\n（也可以运行 ticketdeck report --save）。");
        var listAll = r.Proposals ?? [];
        var actionable = Actionable();
        var dismissed = listAll.Where(p => p.Status == "dismissed").ToList();
        var isToday = r.Date == DailyReport.Today;
        var generating = job?.Running == true;

        var s = new StackPanel { Margin = new Thickness(22, 16, 22, 16) };
        var top = new DockPanel();
        if (isToday)
        {
            FrameworkElement right = generating ? Txt("生成中…", 11, Dim) : Btn(r.Proposals is null ? "生成提议" : "重新生成", Generate);
            right.ToolTip = "在后台用 Claude Code 检查所有项目的工单和仓库（只读），把值得清理的任务写进今天的计划，约一两分钟";
            DockPanel.SetDock(right, System.Windows.Controls.Dock.Right);
            top.Children.Add(right);
        }
        var title = new StackPanel { Orientation = Orientation.Horizontal };
        title.Children.Add(Txt(r.DayTitle, 17, Fore, bold: true));
        title.Children.Add(Txt("清理类任务：同意后在项目里新开 Claude Code 会话处理，按回车开始", 11.5, Dim, margin: new Thickness(10, 4, 0, 0)));
        top.Children.Add(title);
        s.Children.Add(top);
        var failure = startError ?? (job?.State == "failed" && isToday ? job.Error : null);
        if (failure is not null) s.Children.Add(Selectable(failure, 11.5, new SolidColorBrush(Red)));
        if (generating) s.Children.Add(Txt("在后台运行，写完会自动出现在这里。", 11.5, Dim, margin: new Thickness(0, 8, 0, 0)));
        if (listAll.Count == 0)
            s.Children.Add(Txt(r.Proposals is null ? "还没有提议。每天早上 8 点会和今日计划一起生成，也可以现在生成。" : "没有需要清理的任务。", 12.5, Dim, margin: new Thickness(0, 16, 0, 0)));
        else if (actionable.Count == 0)
            s.Children.Add(Txt("提议都已处理。", 12.5, Dim, margin: new Thickness(0, 16, 0, 0)));
        s.Children.Add(new Border { Height = 8 });
        for (var i = 0; i < actionable.Count; i++) s.Children.Add(ProposalRow(actionable[i], i));
        if (dismissed.Count > 0)
        {
            s.Children.Add(new Border { Height = 14 });
            s.Children.Add(Rule());
            s.Children.Add(Fold("已忽略", dismissed.Count, Gray, () => dismissed.Select(p =>
            {
                var line = new DockPanel { Margin = new Thickness(0, 1, 0, 1) };
                var restore = Btn("恢复", () => RestoreProposal(p));
                DockPanel.SetDock(restore, System.Windows.Controls.Dock.Right);
                line.Children.Add(restore);
                var proj = Txt(p.Project, 12, Dim, margin: new Thickness(0, 0, 6, 0));
                DockPanel.SetDock(proj, System.Windows.Controls.Dock.Left);
                line.Children.Add(proj);
                line.Children.Add(Txt(p.Title, 12, Fore));
                return (FrameworkElement)line;
            })));
        }
        return new ScrollViewer { Content = s, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    FrameworkElement ProposalRow(DailyReport.Proposal p, int n)
    {
        var started = p.Status == "started";
        var selected = n == proposalIndex;
        var row = new DockPanel();
        var icon = Txt(started ? "✓" : "✦", 14, new SolidColorBrush(started ? Green : Teal), margin: new Thickness(0, 0, 12, 0));
        DockPanel.SetDock(icon, System.Windows.Controls.Dock.Left);
        row.Children.Add(icon);
        var acts = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
        var run = Btn(started ? "再开一次" : "执行", () => ProposalAction(p, true));
        run.ToolTip = $"在 {p.Project} 里新开一个 Claude Code 会话，填好任务说明，按回车开始";
        acts.Children.Add(run);
        if (!started) acts.Children.Add(Btn("忽略", () => ProposalAction(p, false)));
        DockPanel.SetDock(acts, System.Windows.Controls.Dock.Right);
        row.Children.Add(acts);
        var text = new StackPanel();
        text.Children.Add(Txt($"{p.Project} · {p.Title}", 13, Fore, wrap: true));
        var meta = new WrapPanel { Margin = new Thickness(0, 3, 0, 0) };
        if (started) meta.Children.Add(Txt("已开会话", 10.5, new SolidColorBrush(Green), bold: true, margin: new Thickness(0, 0, 8, 0)));
        if (p.Why is { } why) meta.Children.Add(Txt(why, 11, Fore, margin: new Thickness(0, 0, 8, 0)));
        foreach (var id in p.Tickets ?? [])
        {
            var link = Txt(id, 10.5, new SolidColorBrush(Blue), mono: true, margin: new Thickness(0, 1, 8, 0));
            link.Cursor = Cursors.Hand;
            link.MouseLeftButtonDown += (_, e) => { OpenTicket(p.Root, id); e.Handled = true; };
            meta.Children.Add(link);
        }
        text.Children.Add(meta);
        if (selected)
        {
            var prompt = Txt(p.Prompt, 11, Dim, wrap: true, margin: new Thickness(0, 4, 0, 0));
            prompt.MaxHeight = 100;
            text.Children.Add(prompt);
        }
        row.Children.Add(text);
        var card = Card(row, selected, () => { proposalIndex = n; Render(); });
        card.Opacity = started ? 0.65 : 1;
        if (selected) selectedRow = card;
        return card;
    }

    /// <summary>A folded section: one line with a count; click to open.</summary>
    FrameworkElement Fold(string title, int count, Color c, Func<IEnumerable<FrameworkElement>> content)
    {
        var s = new StackPanel();
        if (count == 0) return s;
        var open = openFolds.Contains(title);
        var head = new DockPanel { Background = Brushes.Transparent, Cursor = Cursors.Hand, Margin = new Thickness(0, 7, 0, 7) };
        var right = Txt($"{count}  {(open ? "▾" : "▸")}", 11, Dim);
        DockPanel.SetDock(right, System.Windows.Controls.Dock.Right);
        head.Children.Add(right);
        var dot = Dot(c, 6);
        dot.Margin = new Thickness(0, 0, 7, 0);
        DockPanel.SetDock(dot, System.Windows.Controls.Dock.Left);
        head.Children.Add(dot);
        head.Children.Add(Txt(title, 12.5, Fore));
        head.MouseLeftButtonDown += (_, e) =>
        {
            if (!openFolds.Remove(title)) openFolds.Add(title);
            Render();
            e.Handled = true;
        };
        s.Children.Add(head);
        if (open)
        {
            var inner = new StackPanel { Margin = new Thickness(13, 0, 0, 8) };
            foreach (var e in content()) inner.Children.Add(e);
            s.Children.Add(inner);
        }
        s.Children.Add(Rule());
        return s;
    }

    // ───────────────────────── Pieces ─────────────────────────

    static Brush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }

    static Border Rule() => new() { Height = 1, Background = Line };

    static FrameworkElement Center(string text) =>
        new TextBlock { Text = text, Foreground = Dim, FontSize = 12.5, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(30) };

    static TextBlock Txt(string text, double size, Brush brush, bool bold = false, bool mono = false, bool wrap = false, Thickness? margin = null, bool center = false) => new()
    {
        Text = text, FontSize = size, Foreground = brush, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        FontFamily = mono ? new FontFamily("Consolas") : SystemFonts.MessageFontFamily,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, Margin = margin ?? new Thickness(0),
        VerticalAlignment = VerticalAlignment.Center, TextAlignment = center ? TextAlignment.Center : TextAlignment.Left,
    };

    /// <summary>Text the user can select and copy (an error, a description line).</summary>
    static TextBox Selectable(string text, double size, Brush brush) => new()
    {
        Text = text, FontSize = size, Foreground = brush, Background = Brushes.Transparent, BorderThickness = new Thickness(0),
        IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Padding = new Thickness(0), Margin = new Thickness(-2, 1, 0, 1),
    };

    /// <summary>Inline markdown, read as plain text: **bold**, `code` and [links](url) lose their marks.</summary>
    static string Inline(string s) =>
        System.Text.RegularExpressions.Regex.Replace(s.Replace("**", "").Replace("`", ""), @"\[([^\]]+)\]\([^)]+\)", "$1");

    static FrameworkElement Dot(Color c, double size) =>
        new System.Windows.Shapes.Ellipse { Width = size, Height = size, Fill = new SolidColorBrush(c), VerticalAlignment = VerticalAlignment.Center };

    static Border Chip(string text, Brush brush) => new()
    {
        Child = Txt(text, 10, brush), Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(4, 0, 0, 0),
        CornerRadius = new CornerRadius(8), Background = Soft, VerticalAlignment = VerticalAlignment.Center,
    };

    static Border StatusChip(string status)
    {
        var c = StatusColor(status);
        var s = new StackPanel { Orientation = Orientation.Horizontal };
        s.Children.Add(Dot(c, 6));
        s.Children.Add(Txt(Names.GetValueOrDefault(status, status), 10, new SolidColorBrush(c), bold: true, margin: new Thickness(4, 0, 0, 0)));
        return new Border
        {
            Child = s, Padding = new Thickness(7, 2, 7, 2), Margin = new Thickness(4, 0, 0, 0), CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(Color.FromArgb(0x29, c.R, c.G, c.B)), VerticalAlignment = VerticalAlignment.Center,
        };
    }

    static Border Btn(string text, Action click)
    {
        var b = new Border
        {
            Child = Txt(text, 11.5, Fore), Padding = new Thickness(9, 3, 9, 3), Margin = new Thickness(0, 0, 6, 0),
            CornerRadius = new CornerRadius(5), Background = Line, Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center,
        };
        b.MouseEnter += (_, _) => b.Background = Dim;
        b.MouseLeave += (_, _) => b.Background = Line;
        b.MouseLeftButtonDown += (_, e) => { e.Handled = true; click(); };
        return b;
    }

    static Border Toggle(string text, bool on, Color c, Action click, double margin = 6)
    {
        var b = new Border
        {
            Child = Txt(text, 12, on ? new SolidColorBrush(c) : Fore, bold: true), Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(margin, 0, 0, 0),
            CornerRadius = new CornerRadius(6), Background = on ? new SolidColorBrush(Color.FromArgb(0x33, c.R, c.G, c.B)) : Soft, Cursor = Cursors.Hand,
        };
        b.MouseLeftButtonDown += (_, e) => { e.Handled = true; click(); };
        return b;
    }

    static Border Card(UIElement content, bool selected, Action select)
    {
        var b = new Border
        {
            Child = content, Padding = new Thickness(12, 9, 12, 9), Margin = new Thickness(0, 0, 0, 6), CornerRadius = new CornerRadius(9),
            Background = selected ? Pick : Soft, BorderBrush = Line, BorderThickness = new Thickness(1),
        };
        b.MouseLeftButtonDown += (_, _) => select();
        return b;
    }

    /// <summary>One colour per status, shared with the web board.</summary>
    static Color StatusColor(string s) => s switch { "doing" => Blue, "review" => Orange, "done" => Green, "dropped" => Red, _ => Gray };

    static Color PriorityColor(string p) => p switch { "P0" => Red, "P1" => Orange, "P2" => Blue, _ => Gray };
}
