using TabStack.Core;

namespace TabStack.Core.Tests;

/// <summary>Following focus, covering a closed window, rebinding after a reboot, labels.</summary>
public sealed class FocusAndRebootTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "tabstack-tests-" + Guid.NewGuid().ToString("N"));
    readonly FakePlatform os = new();
    double now = 1_700_000_000;

    WorkspaceManager Manager() => new(os, new Store(Path.Combine(dir, "state.json")), new HiddenLedger(Path.Combine(dir, "hidden.json")), () => now);

    public void Dispose() { if (Directory.Exists(dir)) Directory.Delete(dir, true); }

    WindowInfo Info(FakePlatform.Win w) => os.Describe(w.Hwnd)!;

    [Fact]
    public void AWindowOfAHiddenWorkspaceComingForwardIsFollowed()
    {
        var code = os.Open(@"c:\code.exe", "proj");
        var chat = os.Open(@"c:\tim.exe", "Chat");
        var m = Manager();
        var home = m.Current;
        m.AddWindow(Info(code));
        var life = m.CreateWorkspace("Life");
        m.SwitchWorkspace(life.Id);
        var tChat = m.AddWindow(Info(chat));
        m.SwitchWorkspace(home.Id);
        Assert.False(os.Get(chat.Hwnd).Visible);

        now += 5; // well after our own switch
        os.Activate(chat.Hwnd); // the app showed its window itself (a message came in)
        m.OnForeground(chat.Hwnd);
        Assert.Equal(life.Id, m.FollowTarget(chat.Hwnd)?.Id);
        m.Follow(chat.Hwnd, life.Id);
        Assert.Equal(life.Id, m.Current.Id);
        Assert.Equal(tChat.Id, m.Current.LastTabID);
        Assert.False(m.FocusOutside);
        Assert.False(os.Get(code.Hwnd).Visible);
    }

    [Fact]
    public void AtStartWindowsOfWorkspacesNotOnScreenArePutAwayAgain()
    {
        var term = os.Open(@"c:\term.exe", "Terminal");
        var code = os.Open(@"c:\code.exe", "proj");
        var chat = os.Open(@"c:\tim.exe", "Chat");
        var m = Manager();
        var home = m.Current;
        m.AddWindow(Info(term));
        m.AddWindow(Info(chat));
        var work = m.CreateWorkspace("Work");
        m.SwitchWorkspace(work.Id);
        m.AddWindow(Info(code));
        m.AddWindow(Info(chat)); // shared with Home
        m.SwitchWorkspace(home.Id);
        // TabStack quit (showing every hidden window) and starts again.
        m.ShowAllHidden();
        Assert.True(os.Get(code.Hwnd).Visible);
        var again = Manager();
        Assert.Equal(1, again.PutAwayUndisplayed());
        Assert.False(os.Get(code.Hwnd).Visible);
        Assert.True(os.Get(term.Hwnd).Visible);
        Assert.True(os.Get(chat.Hwnd).Visible); // Home, on screen, holds it too
        // Coming back to Work shows it again.
        again.SwitchWorkspace(work.Id);
        Assert.True(os.Get(code.Hwnd).Visible);
    }

    [Fact]
    public void FocusHandedOverIsNotFollowed()
    {
        var code = os.Open(@"c:\code.exe", "proj");
        var chat = os.Open(@"c:\tim.exe", "Chat");
        var m = Manager();
        var home = m.Current;
        m.AddWindow(Info(code));
        var life = m.CreateWorkspace("Life");
        m.SwitchWorkspace(life.Id);
        m.AddWindow(Info(chat));
        m.SwitchWorkspace(home.Id);
        now += 5;
        m.NoteHandoff(); // e.g. a window was just minimized
        os.Activate(chat.Hwnd);
        Assert.Null(m.FollowTarget(chat.Hwnd));
        m.Follow(chat.Hwnd, life.Id);
        Assert.Equal(home.Id, m.Current.Id);
    }

    [Fact]
    public void AnUnrelatedWindowClearsTheHighlight()
    {
        var code = os.Open(@"c:\code.exe", "proj");
        var other = os.Open(@"c:\calc.exe", "Calculator");
        var m = Manager();
        var t = m.AddWindow(Info(code));
        m.SelectTab(t.Id);
        Assert.False(m.FocusOutside);
        os.Activate(other.Hwnd);
        m.OnForeground(other.Hwnd);
        Assert.True(m.FocusOutside);
        Assert.Null(m.FollowTarget(other.Hwnd));
        os.Activate(code.Hwnd);
        m.OnForeground(code.Hwnd);
        Assert.False(m.FocusOutside);
    }

    [Fact]
    public void ClosingTheShownWindowShowsTheNextOpenTab()
    {
        var a = os.Open(@"c:\a.exe", "A");
        var b = os.Open(@"c:\b.exe", "B");
        var c = os.Open(@"c:\c.exe", "C");
        var m = Manager();
        var ta = m.AddWindow(Info(a));
        var tb = m.AddWindow(Info(b));
        var tc = m.AddWindow(Info(c));
        m.SelectTab(tb.Id);
        os.Close(b.Hwnd);
        os.Foreground = 0; // Windows gave the focus to the desktop
        m.CoverClosed(tb.Id, b.Hwnd);
        Assert.Equal(tc.Id, m.Current.LastTabID);
        Assert.Equal(c.Hwnd, os.Foreground);
        Assert.Contains(m.Current.Tabs, t => t.Id == tb.Id); // the closed tab stays

        // The last tab closes: the one before it covers.
        os.Close(c.Hwnd);
        os.Foreground = 0;
        m.CoverClosed(tc.Id, c.Hwnd);
        Assert.Equal(ta.Id, m.Current.LastTabID);
    }

    [Fact]
    public void ClosingAWindowWhenWindowsFocusedAnotherOfTheWorkspaceKeepsThat()
    {
        var a = os.Open(@"c:\a.exe", "A");
        var b = os.Open(@"c:\b.exe", "B");
        var c = os.Open(@"c:\c.exe", "C");
        var m = Manager();
        var ta = m.AddWindow(Info(a));
        var tb = m.AddWindow(Info(b));
        m.AddWindow(Info(c));
        m.SelectTab(tb.Id);
        os.Close(b.Hwnd);
        os.Activate(a.Hwnd);
        m.CoverClosed(tb.Id, b.Hwnd);
        Assert.Equal(ta.Id, m.Current.LastTabID);
    }

    [Fact]
    public void AfterARebootTabsRebindByTitleNotByOldHandle()
    {
        var mail = os.Open(@"c:\chrome.exe", "Inbox");
        var docs = os.Open(@"c:\chrome.exe", "Docs");
        var m = Manager();
        var tMail = m.AddWindow(Info(mail));
        var tDocs = m.AddWindow(Info(docs));
        Assert.Equal(100, tMail.Hwnd);

        os.Reboot();
        // The new windows come up in the other order: handle 100 is now Docs.
        var docs2 = os.Open(@"c:\chrome.exe", "Docs");
        var mail2 = os.Open(@"c:\chrome.exe", "Inbox");
        Assert.Equal(100, docs2.Hwnd);

        var m2 = Manager();
        var t1 = m2.Current.Tab(tMail.Id)!;
        var t2 = m2.Current.Tab(tDocs.Id)!;
        Assert.Equal(mail2.Hwnd, t1.Hwnd);
        Assert.Equal(docs2.Hwnd, t2.Hwnd);
    }

    [Fact]
    public void CloseWindowClosesItAndPicksTheNeighbour()
    {
        var a = os.Open(@"c:\a.exe", "A");
        var b = os.Open(@"c:\b.exe", "B");
        var m = Manager();
        var ta = m.AddWindow(Info(a));
        var tb = m.AddWindow(Info(b));
        m.SelectTab(ta.Id);
        Assert.True(m.CloseWindow(a.Hwnd, out var next));
        Assert.Equal(tb.Id, next);
        Assert.DoesNotContain(m.Current.Tabs, t => t.Id == ta.Id);
        Assert.Null(os.Describe(a.Hwnd));
    }

    [Fact]
    public void CloseWindowOnASharedWindowOnlyDropsItHere()
    {
        var claude = os.Open(@"c:\claude.exe", "Claude");
        var code = os.Open(@"c:\code.exe", "proj");
        var m = Manager();
        var home = m.Current;
        m.AddWindow(Info(code));
        m.AddWindow(Info(claude));
        var other = m.CreateWorkspace("Other");
        m.SwitchWorkspace(other.Id);
        m.AddWindow(Info(claude));
        Assert.True(m.CloseWindow(claude.Hwnd, out _));
        Assert.NotNull(os.Describe(claude.Hwnd));       // still running
        Assert.False(os.Get(claude.Hwnd).Visible);      // out of sight here
        Assert.Empty(m.Current.Tabs);
        var kept = home.Tabs.Single(t => t.Hwnd == claude.Hwnd);
        Assert.Null(kept.Shared);
    }

    [Fact]
    public void CloseWindowOnAnUnknownWindowStillClosesIt()
    {
        var x = os.Open(@"c:\x.exe", "X");
        var m = Manager();
        Assert.True(m.CloseWindow(x.Hwnd, out var next));
        Assert.Null(next);
        Assert.False(m.CloseWindow(x.Hwnd, out _));
    }

    [Theory]
    [InlineData("Inbox (18) - someone@gmail.com - Gmail - Google Chrome", "Inbox (18) - someone@gmail.com - Gmail")]
    [InlineData("(3) Messages - Google Chrome", "Messages")]
    [InlineData("新标签页 和另外 3 个页面 - 个人 - Microsoft\u200b Edge", "新标签页")]
    [InlineData("tdx 和 1 个其他选项卡 - 文件资源管理器", "tdx")]
    [InlineData("YouTube - Audio playing - Google Chrome", "YouTube")]
    [InlineData("Notes", "Notes")]
    [InlineData("Google Chrome", "Google Chrome")]
    public void TitlesLoseTheirNoise(string title, string label) => Assert.Equal(label, TitleLabels.Clean(title));

    // ───── Apps that close to the tray (Claude, chat apps): they hide their own window ─────

    [Fact]
    public void AWindowItsAppHidIsNotShownByClickingItsTab()
    {
        var claude = os.Open(@"c:\claude.exe", "Claude");
        var m = Manager();
        var tab = m.AddWindow(Info(claude));
        os.Hide(claude.Hwnd); // closed to the tray
        Assert.Null(m.Live(claude.Hwnd));
        Assert.False(m.SelectTab(tab.Id)); // the caller starts the app instead
        Assert.False(os.Get(claude.Hwnd).Visible);
    }

    [Fact]
    public void ComingBackToAWorkspaceDoesNotShowAWindowItsAppHid()
    {
        var claude = os.Open(@"c:\claude.exe", "Claude");
        var m = Manager();
        var home = m.Current;
        m.AddWindow(Info(claude));
        os.Hide(claude.Hwnd); // closed to the tray while on screen
        var other = m.CreateWorkspace("Other");
        m.SwitchWorkspace(other.Id);
        m.SwitchWorkspace(home.Id);
        Assert.False(os.Get(claude.Hwnd).Visible);
    }

    [Fact]
    public void AWindowWeHidIsStillShownWhenComingBack()
    {
        var a = os.Open(@"c:.exe", "A");
        var m = Manager();
        var home = m.Current;
        var tab = m.AddWindow(Info(a));
        var other = m.CreateWorkspace("Other");
        m.SwitchWorkspace(other.Id);
        Assert.NotNull(m.Live(a.Hwnd)); // hidden, but by us
        m.SwitchWorkspace(home.Id);
        Assert.True(os.Get(a.Hwnd).Visible);
        Assert.Equal(tab.Id, m.Current.LastTabID);
    }

    [Fact]
    public void TheAppShowingItsWindowAgainRebindsTheTab()
    {
        var claude = os.Open(@"c:\claude.exe", "Claude");
        var m = Manager();
        var tab = m.AddWindow(Info(claude));
        os.Hide(claude.Hwnd);
        m.Tick();
        Assert.Null(tab.Hwnd); // shown as closed
        os.Show(claude.Hwnd); // the app was started again and brought its window back
        Assert.True(m.SelectTab(tab.Id));
        Assert.Equal(claude.Hwnd, tab.Hwnd);
    }
}
