using TabStack.Core;

namespace TabStack.Core.Tests;

public sealed class WorkspaceManagerTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "tabstack-tests-" + Guid.NewGuid().ToString("N"));
    readonly FakePlatform os = new();
    double now = 1_700_000_000;

    Store Store => new(Path.Combine(dir, "state.json"));
    HiddenLedger Ledger() => new(Path.Combine(dir, "hidden.json"));
    WorkspaceManager Manager(HiddenLedger? ledger = null) => new(os, Store, ledger ?? Ledger(), () => now);

    public void Dispose() { if (Directory.Exists(dir)) Directory.Delete(dir, true); }

    WindowInfo Info(FakePlatform.Win w) => os.Describe(w.Hwnd)!;

    [Fact]
    public void StartsWithOneWorkspace()
    {
        var m = Manager();
        Assert.Single(m.Workspaces);
        Assert.Equal(m.Workspaces[0].Id, m.Current.Id);
    }

    [Fact]
    public void SwitchingHidesTheOldWindowsAndShowsTheNew()
    {
        var code = os.Open(@"c:\code.exe", "proj");
        var chrome = os.Open(@"c:\chrome.exe", "Mail");
        var m = Manager();
        var first = m.Current;
        m.AddWindow(Info(code));
        var second = m.CreateWorkspace("Web");
        m.SwitchWorkspace(second.Id);
        Assert.False(os.Get(code.Hwnd).Visible);
        m.AddWindow(Info(chrome));

        m.SwitchWorkspace(first.Id);
        Assert.True(os.Get(code.Hwnd).Visible);
        Assert.False(os.Get(chrome.Hwnd).Visible);
        Assert.Equal(code.Hwnd, os.Foreground);
    }

    [Fact]
    public void SharedWindowStaysVisibleAcrossWorkspaces()
    {
        var chat = os.Open(@"c:\chat.exe", "Chat");
        var m = Manager();
        var first = m.Current;
        m.AddWindow(Info(chat));
        var second = m.CreateWorkspace("B");
        m.SwitchWorkspace(second.Id);
        os.Show(chat.Hwnd);
        m.AddWindow(Info(chat));
        Assert.All(m.Workspaces.SelectMany(w => w.Tabs), t => Assert.True(t.Shared));

        m.SwitchWorkspace(first.Id);
        Assert.True(os.Get(chat.Hwnd).Visible);
    }

    [Fact]
    public void HiddenWindowsAreRecordedAndRestoredAfterACrash()
    {
        var a = os.Open(@"c:\a.exe", "A");
        var m = Manager();
        m.AddWindow(Info(a));
        m.SwitchWorkspace(m.CreateWorkspace("B").Id);
        Assert.False(os.Get(a.Hwnd).Visible);

        // TabStack dies; the next start (or the watchdog) reads the ledger from disk.
        var shown = HiddenLedger.RestoreFrom(Path.Combine(dir, "hidden.json"), os);
        Assert.Equal(1, shown);
        Assert.True(os.Get(a.Hwnd).Visible);
        Assert.Empty(Ledger().Entries);
    }

    [Fact]
    public void LedgerIgnoresAWindowWhoseProcessWasReplaced()
    {
        var a = os.Open(@"c:\a.exe", "A");
        var m = Manager();
        m.AddWindow(Info(a));
        m.SwitchWorkspace(m.CreateWorkspace("B").Id);
        os.Get(a.Hwnd).Start = 99; // handle now belongs to a different process instance
        Assert.Equal(0, HiddenLedger.RestoreFrom(Path.Combine(dir, "hidden.json"), os));
        Assert.False(os.Get(a.Hwnd).Visible);
    }

    [Fact]
    public void LockedWindowsAreNotHidden()
    {
        var admin = os.Open(@"c:\admin.exe", "Admin");
        admin.Locked = true;
        var m = Manager();
        m.AddWindow(Info(admin));
        m.SwitchWorkspace(m.CreateWorkspace("B").Id);
        Assert.True(os.Get(admin.Hwnd).Visible);
    }

    [Fact]
    public void ClosedWindowRebindsByTitleThenAnyFreeWindow()
    {
        var a = os.Open(@"c:\code.exe", "alpha");
        var b = os.Open(@"c:\code.exe", "beta");
        var m = Manager();
        var ta = m.AddWindow(Info(a));
        var tb = m.AddWindow(Info(b));
        os.Close(a.Hwnd);
        os.Close(b.Hwnd);
        var b2 = os.Open(@"c:\code.exe", "beta");
        var a2 = os.Open(@"c:\code.exe", "alpha");

        m.Tick();
        Assert.Null(ta.Hwnd);
        Assert.True(m.SelectTab(tb.Id));
        Assert.Equal(b2.Hwnd, tb.Hwnd);
        Assert.True(m.SelectTab(ta.Id));
        Assert.Equal(a2.Hwnd, ta.Hwnd);
    }

    [Fact]
    public void RebindDoesNotStealAWindowAnotherTabHolds()
    {
        var a = os.Open(@"c:\code.exe", "alpha");
        var m = Manager();
        var ta = m.AddWindow(Info(a));
        var tGone = m.AddWindow(Info(os.Open(@"c:\code.exe", "gone")));
        os.Close(tGone.Hwnd!.Value);
        Assert.False(m.SelectTab(tGone.Id));
        Assert.Equal(a.Hwnd, ta.Hwnd);
    }

    [Fact]
    public void StateSurvivesARestart()
    {
        var a = os.Open(@"c:\a.exe", "A");
        var m = Manager();
        m.AddWindow(Info(a));
        m.RenameWorkspace(m.Current.Id, "Main");
        var b = m.CreateWorkspace("Other");
        m.SetPinned(b.Id, true);

        var m2 = Manager();
        Assert.Equal(["Main", "Other"], m2.Workspaces.Select(w => w.Name));
        Assert.Equal(a.Hwnd, m2.Current.Tabs[0].Hwnd);
        Assert.True(m2.Workspaces[1].Pinned);
    }

    [Fact]
    public void RestartDropsHandlesThatNowNameAnotherApp()
    {
        var a = os.Open(@"c:\a.exe", "A");
        Manager().AddWindow(Info(a));
        a.AppID = @"c:\other.exe";
        Assert.Null(Manager().Current.Tabs[0].Hwnd);
    }

    [Fact]
    public void DeletingAWorkspaceShowsItsHiddenWindows()
    {
        var a = os.Open(@"c:\a.exe", "A");
        var m = Manager();
        var first = m.Current;
        m.AddWindow(Info(a));
        m.SwitchWorkspace(m.CreateWorkspace("B").Id);
        m.DeleteWorkspace(first.Id);
        Assert.True(os.Get(a.Hwnd).Visible);
        Assert.Single(m.Workspaces);
    }

    [Fact]
    public void DwellingCountsAsUse()
    {
        var m = Manager();
        var before = m.Current.Usage!.Count;
        now += Frecency.DwellInterval + 1;
        m.Tick();
        Assert.Equal(before + 1, m.Current.Usage!.Count);
    }

    [Fact]
    public void ForegroundSelectsTheTab()
    {
        var a = os.Open(@"c:\a.exe", "A");
        var b = os.Open(@"c:\b.exe", "B");
        var m = Manager();
        var ta = m.AddWindow(Info(a));
        m.AddWindow(Info(b));
        m.OnForeground(a.Hwnd);
        Assert.Equal(ta.Id, m.Current.LastTabID);
    }

    [Fact]
    public void JsonUsesMacFieldNamesAndLowercaseEnums()
    {
        var m = Manager();
        m.Current.Sleep = new SleepState { Level = SleepLevel.Throttled, Since = 1 };
        m.Save();
        var json = File.ReadAllText(Path.Combine(dir, "state.json"));
        Assert.Contains("\"currentWorkspace\"", json);
        Assert.Contains("\"usage\"", json);
        Assert.Contains("\"throttled\"", json);
        Assert.DoesNotContain("\"customName\"", json); // nulls omitted
    }

    [Fact]
    public void RebindPrefersAWindowWeCanHide()
    {
        var m = Manager();
        var tab = m.AddWindow(Info(os.Open(@"c:\ps.exe", "mine")));
        os.Close(tab.Hwnd!.Value);
        os.Open(@"c:\ps.exe", "admin").Locked = true;
        var free = os.Open(@"c:\ps.exe", "other");
        os.Windows.Reverse(); // the locked one comes first in Z order
        Assert.True(m.SelectTab(tab.Id));
        Assert.Equal(free.Hwnd, tab.Hwnd);
    }

    [Fact]
    public void LedgerForgetsWindowsClosedWhileHidden()
    {
        var a = os.Open(@"c:\a.exe", "A");
        var ledger = Ledger();
        var m = Manager(ledger);
        m.AddWindow(Info(a));
        m.SwitchWorkspace(m.CreateWorkspace("B").Id);
        os.Close(a.Hwnd);
        ledger.Prune(os);
        Assert.Empty(ledger.Entries);
    }

    [Fact]
    public void ReturningRestoresStackingAndFocusButNotPlacement()
    {
        var a = os.Open(@"c:\a.exe", "A");
        var b = os.Open(@"c:\b.exe", "B");
        var c = os.Open(@"c:\c.exe", "C");
        var m = Manager();
        var home = m.Current;
        m.AddWindow(Info(a)); m.AddWindow(Info(b)); m.AddWindow(Info(c));
        a.Rect = new Rect(200, 50, 600, 400);
        b.State = PlacementState.Maximized;
        c.Minimized = true; c.State = PlacementState.Minimized;
        os.Activate(b.Hwnd);                       // stack: b, c(minimized), a
        m.OnForeground(b.Hwnd);

        m.SwitchWorkspace(m.CreateWorkspace("X").Id);
        // Meanwhile the user (or the app) changes them: that is how they come back.
        a.Rect = new Rect(300, 60, 500, 300); b.State = PlacementState.Normal;
        m.SwitchWorkspace(home.Id);

        Assert.Equal(new Rect(300, 60, 500, 300), a.Rect);
        Assert.Equal(PlacementState.Normal, b.State);
        Assert.Equal(PlacementState.Minimized, c.State);
        Assert.Equal(b.Hwnd, os.Foreground);
        Assert.Equal([a.Hwnd, b.Hwnd], os.LastRaise); // bottom to top, minimized left out
    }

    [Fact]
    public void AppsThatCloseWhenHiddenAreMinimizedNextTime()
    {
        var a = os.Open(@"c:\dialog.exe", "A");
        var m = Manager();
        var home = m.Current;
        m.AddWindow(Info(a));
        string? notice = null;
        m.Notice += n => notice = n;
        m.SwitchWorkspace(m.CreateWorkspace("X").Id);
        os.Close(a.Hwnd);
        m.OnDestroyed(a.Hwnd);
        Assert.Contains(@"c:\dialog.exe", m.Settings.MinimizeApps);
        Assert.NotNull(notice);

        m.SwitchWorkspace(home.Id);
        var a2 = os.Open(@"c:\dialog.exe", "A");
        m.SelectTab(home.Tabs[0].Id);
        m.SwitchWorkspace(m.Workspaces[1].Id);
        Assert.True(a2.Visible);
        Assert.True(a2.Minimized);
        Assert.Empty(Ledger().Entries);
    }

    [Fact]
    public void WindowClosedLongAfterHidingDoesNotChangeSettings()
    {
        var a = os.Open(@"c:\a.exe", "A");
        var m = Manager();
        m.AddWindow(Info(a));
        m.SwitchWorkspace(m.CreateWorkspace("X").Id);
        now += 60;
        os.Close(a.Hwnd);
        m.OnDestroyed(a.Hwnd);
        Assert.Empty(m.Settings.MinimizeApps);
    }

    [Fact]
    public void SwitchingBackLeavesWindowsAsTheyAre()
    {
        var a = os.Open(@"c:\a.exe", "A");
        a.Rect = new Rect(300, 200, 640, 480);
        var m = Manager();
        var home = m.Current;
        m.AddWindow(Info(a));
        var other = m.CreateWorkspace("Other");
        m.SwitchWorkspace(other.Id);
        // The window changed while it was out of sight (the app resized itself, say):
        // coming back does not undo that.
        a.Rect = new Rect(100, 100, 900, 700);
        os.LastLayout.Clear();
        m.SwitchWorkspace(home.Id);
        Assert.True(os.Get(a.Hwnd).Visible);
        Assert.Equal(new Rect(100, 100, 900, 700), a.Rect);
        Assert.Empty(os.LastLayout); // nothing was placed
        Assert.Equal(a.Hwnd, os.Foreground);
    }

    [Fact]
    public void StackingOrderComesBack()
    {
        var a = os.Open(@"c:\a.exe", "A");
        var b = os.Open(@"c:\b.exe", "B");
        var m = Manager();
        var home = m.Current;
        m.AddWindow(Info(a));
        m.AddWindow(Info(b));
        os.Activate(a.Hwnd); // a on top
        var other = m.CreateWorkspace("Other");
        m.SwitchWorkspace(other.Id);
        m.SwitchWorkspace(home.Id);
        Assert.Equal([b.Hwnd, a.Hwnd], os.LastRaise);
        Assert.Equal(a.Hwnd, os.Windows[0].Hwnd);
    }

    [Fact]
    public void AppsMinimizedInsteadOfHiddenComeBackMaximized()
    {
        var a = os.Open(@"c:\a.exe", "A");
        a.State = PlacementState.Maximized;
        var m = Manager();
        var home = m.Current;
        m.AddWindow(Info(a));
        m.UpdateSettings(s => s.MinimizeApps.Add(@"c:\a.exe"));
        var other = m.CreateWorkspace("Other");
        m.SwitchWorkspace(other.Id);
        Assert.Equal(PlacementState.Minimized, os.Get(a.Hwnd).State);
        m.SwitchWorkspace(home.Id);
        Assert.Equal(PlacementState.Maximized, os.Get(a.Hwnd).State);
    }

    /// <summary>Two windows snapped side by side (left and right half) and a third elsewhere.</summary>
    (WorkspaceManager m, AppTab ta, AppTab tb, AppTab tc, FakePlatform.Win a, FakePlatform.Win b, FakePlatform.Win c) Snapped()
    {
        var a = os.Open(@"c:\a.exe", "A");
        var b = os.Open(@"c:\b.exe", "B");
        var c = os.Open(@"c:\c.exe", "C");
        // Window rects include the 7 px invisible borders, so snapped neighbours overlap a little.
        a.Rect = new Rect(57, 0, 942, 1047);
        a.State = PlacementState.Snapped;
        b.Rect = new Rect(985, 0, 942, 1047);
        b.State = PlacementState.Snapped;
        c.Rect = new Rect(300, 200, 640, 480);
        var m = Manager();
        var ta = m.AddWindow(Info(a));
        var tb = m.AddWindow(Info(b));
        var tc = m.AddWindow(Info(c));
        return (m, ta, tb, tc, a, b, c);
    }

    [Fact]
    public void SnappedNeighboursFormAGroup()
    {
        var (m, ta, tb, tc, a, b, c) = Snapped();
        var groups = m.SnapGroups(m.Current);
        Assert.Equal(groups[ta.Id], groups[tb.Id]);
        Assert.False(groups.ContainsKey(tc.Id));
        Assert.Equal(2, m.SnapGroup(m.Current, a.Hwnd).Count);
        Assert.Single(m.SnapGroup(m.Current, c.Hwnd));
    }

    [Fact]
    public void SelectingASnappedTabBringsItsGroupForward()
    {
        var (m, ta, _, tc, a, b, c) = Snapped();
        m.SelectTab(tc.Id);
        Assert.Equal(c.Hwnd, os.Windows[0].Hwnd);
        m.SelectTab(ta.Id);
        Assert.Equal(a.Hwnd, os.Foreground);
        Assert.Contains(b.Hwnd, os.LastRaise);
        // Both halves are above the third window, and nobody was moved.
        var order = os.Windows.Select(w => w.Hwnd).ToList();
        Assert.True(order.IndexOf(b.Hwnd) < order.IndexOf(c.Hwnd));
        Assert.Equal(new Rect(985, 0, 942, 1047), b.Rect);
    }

    [Fact]
    public void DraggingAWindowAwayLeavesTheGroup()
    {
        var (m, ta, tb, _, _, b, _) = Snapped();
        b.Rect = new Rect(1200, 300, 600, 500);
        b.State = PlacementState.Normal;
        var groups = m.SnapGroups(m.Current);
        Assert.False(groups.ContainsKey(ta.Id));
        Assert.False(groups.ContainsKey(tb.Id));
    }
}
