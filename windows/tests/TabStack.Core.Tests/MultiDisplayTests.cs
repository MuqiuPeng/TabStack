using TabStack.Core;

namespace TabStack.Core.Tests;

/// <summary>Every display with a sidebar shows a workspace of its own.</summary>
public sealed class MultiDisplayTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "tabstack-tests-" + Guid.NewGuid().ToString("N"));
    readonly FakePlatform os = new();
    readonly double now = 1_700_000_000;

    WorkspaceManager Manager() => new(os, new Store(Path.Combine(dir, "state.json")), new HiddenLedger(Path.Combine(dir, "hidden.json")), () => now);

    public void Dispose() { if (Directory.Exists(dir)) Directory.Delete(dir, true); }

    WindowInfo Info(FakePlatform.Win w) => os.Describe(w.Hwnd)!;

    /// <summary>Workspace A (editor on display 1), B (browser on display 2), C (mail, hidden):
    /// display 1 focused on A, display 2 on B.</summary>
    (WorkspaceManager m, Workspace a, Workspace b, Workspace c, FakePlatform.Win editor, FakePlatform.Win browser, FakePlatform.Win mail) Setup()
    {
        os.AddSecondMonitor();
        var editor = os.Open(@"c:\code.exe", "proj");
        editor.Rect = new Rect(200, 100, 800, 600);
        var browser = os.Open(@"c:\chrome.exe", "Docs");
        browser.Rect = new Rect(2100, 100, 900, 700);
        var mail = os.Open(@"c:\mail.exe", "Inbox");
        mail.Rect = new Rect(300, 200, 600, 500);

        var m = Manager();
        var a = m.Current;
        m.AddWindow(Info(editor));
        var b = m.CreateWorkspace("B");
        var c = m.CreateWorkspace("C");
        m.SwitchWorkspace(c.Id);
        m.AddWindow(Info(mail));
        m.SwitchWorkspace(b.Id);
        m.AddWindow(Info(browser));
        m.SwitchWorkspace(a.Id);
        // Display 2 gets B once it gets a sidebar of its own.
        m.UpdateSettings(_ => { });
        m.AssignDisplays();
        if (m.WorkspaceOn("DISPLAY2")?.Id != b.Id)
        {
            m.FocusDisplay("DISPLAY2");
            m.SwitchWorkspace(b.Id);
            m.FocusDisplay("DISPLAY1");
        }
        return (m, a, b, c, editor, browser, mail);
    }

    [Fact]
    public void EachDisplayGetsADifferentWorkspace()
    {
        var (m, a, b, _, editor, browser, mail) = Setup();
        Assert.Equal("DISPLAY1", m.FocusedDisplay);
        Assert.Equal(a.Id, m.WorkspaceOn("DISPLAY1")!.Id);
        Assert.Equal(b.Id, m.WorkspaceOn("DISPLAY2")!.Id);
        Assert.True(os.Get(editor.Hwnd).Visible);
        Assert.True(os.Get(browser.Hwnd).Visible);
        Assert.False(os.Get(mail.Hwnd).Visible);
        Assert.Contains(b.Id, m.ActiveIDs);
    }

    [Fact]
    public void SwitchingOnOneDisplayLeavesTheOtherAlone()
    {
        var (m, _, b, c, editor, browser, mail) = Setup();
        m.SwitchWorkspace(c.Id);
        Assert.False(os.Get(editor.Hwnd).Visible);
        Assert.True(os.Get(mail.Hwnd).Visible);
        Assert.True(os.Get(browser.Hwnd).Visible);
        Assert.Equal(new Rect(2100, 100, 900, 700), os.Get(browser.Hwnd).Rect);
        Assert.Equal(b.Id, m.WorkspaceOn("DISPLAY2")!.Id);
    }

    [Fact]
    public void ChoosingTheOtherDisplaysWorkspaceTradesThem()
    {
        var (m, a, b, _, editor, browser, _) = Setup();
        m.SwitchWorkspace(b.Id);
        Assert.Equal(b.Id, m.Current.Id);
        Assert.Equal(a.Id, m.WorkspaceOn("DISPLAY2")!.Id);
        // Both sets stay on screen, each moved to the other monitor at the same offset.
        Assert.True(os.Get(editor.Hwnd).Visible);
        Assert.True(os.Get(browser.Hwnd).Visible);
        Assert.Equal(new Rect(1984 + (200 - 64), 100, 800, 600), os.Get(editor.Hwnd).Rect);
        Assert.Equal(new Rect(64 + (2100 - 1984), 100, 900, 700), os.Get(browser.Hwnd).Rect);
        Assert.Equal(browser.Hwnd, os.Foreground);
    }

    [Fact]
    public void UsingAWindowOnTheOtherDisplayFocusesIt()
    {
        var (m, _, b, _, _, browser, _) = Setup();
        os.Activate(browser.Hwnd);
        m.OnForeground(browser.Hwnd);
        Assert.Equal("DISPLAY2", m.FocusedDisplay);
        Assert.Equal(b.Id, m.Current.Id);
    }

    [Fact]
    public void HotkeysActOnTheFocusedDisplay()
    {
        var (m, a, _, c, editor, browser, mail) = Setup();
        m.FocusDisplay("DISPLAY2");
        m.SwitchWorkspace(c.Id);
        Assert.False(os.Get(browser.Hwnd).Visible);
        Assert.True(os.Get(editor.Hwnd).Visible);
        Assert.Equal(a.Id, m.WorkspaceOn("DISPLAY1")!.Id);
        // C's window was last on display 1, which shows A: it comes to display 2.
        Assert.True(os.Get(mail.Hwnd).Visible);
        Assert.True(os.Get(mail.Hwnd).Rect.X >= 1920);
    }

    [Fact]
    public void UnpluggedDisplaysWorkspaceIsPutAwayAndComesBack()
    {
        var (m, _, b, _, editor, browser, _) = Setup();
        os.MonitorList.RemoveAt(1);
        m.AssignDisplays();
        Assert.Null(m.WorkspaceOn("DISPLAY2"));
        Assert.False(os.Get(browser.Hwnd).Visible);
        Assert.True(os.Get(editor.Hwnd).Visible);

        os.AddSecondMonitor();
        m.AssignDisplays();
        Assert.Equal(b.Id, m.WorkspaceOn("DISPLAY2")!.Id);
        Assert.True(os.Get(browser.Hwnd).Visible);
    }

    [Fact]
    public void MonitorsWithoutASidebarShowNoWorkspace()
    {
        var (m, a, b, _, editor, browser, _) = Setup();
        m.UpdateSettings(s => s.NoSidebarMonitors.Add("DISPLAY1"));
        m.AssignDisplays();
        Assert.Equal("DISPLAY2", m.FocusedDisplay);
        Assert.Single(m.SidebarMonitors());
        // The focused display moved: it keeps showing the workspace that was current.
        Assert.Equal(a.Id, m.Current.Id);
        Assert.Null(m.WorkspaceOn("DISPLAY1"));
        Assert.True(os.Get(editor.Hwnd).Visible);
        Assert.False(os.Get(browser.Hwnd).Visible);
        _ = b;
    }

    [Fact]
    public void FocusMovesBetweenDisplays()
    {
        var (m, a, b, _, _, _, _) = Setup();
        Assert.True(m.FocusDisplay("DISPLAY2"));
        Assert.Equal(b.Id, m.Current.Id);
        Assert.Equal(a.Id, m.WorkspaceOn("DISPLAY1")!.Id);
        Assert.False(m.FocusDisplay("DISPLAY2"));
    }
}
