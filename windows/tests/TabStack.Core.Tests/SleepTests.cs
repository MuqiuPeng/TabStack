using TabStack.Core;

namespace TabStack.Core.Tests;

/// <summary>A fake for efficiency mode, sound, memory and reopening.</summary>
sealed class FakeSleep(FakePlatform os) : ISleepPlatform
{
    public readonly HashSet<int> Throttled = new();
    public readonly HashSet<int> Audio = new();
    public int Load = 40;
    public int Reopens;

    public IReadOnlyList<ThrottledProcess> Throttle(int pid)
    {
        Throttled.Add(pid);
        return [new ThrottledProcess(pid, pid, 1, 32)];
    }

    public void Unthrottle(ThrottledProcess p) => Throttled.Remove(p.Pid);
    public bool PlayingAudio(int pid) => Audio.Contains(pid);
    public int MemoryLoad() => Load;

    /// <summary>"Editors" (code.exe) can be reopened: the folder is the window title.</summary>
    public Reopen? Capture(WindowInfo w) =>
        w.AppID.EndsWith("code.exe") && !w.Title.StartsWith("●") ? new Reopen { Folder = @"e:\projects\" + w.Title } : null;

    public bool Reopen(AppTab tab)
    {
        Reopens++;
        os.Open(tab.AppID, Path.GetFileName(tab.Reopen!.Folder!), pid: 50 + Reopens);
        return true;
    }
}

public sealed class SleepTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "tabstack-tests-" + Guid.NewGuid().ToString("N"));
    readonly FakePlatform os = new();
    readonly FakeSleep power;
    double now = 1_700_000_000;

    public SleepTests() => power = new FakeSleep(os);

    WorkspaceManager Manager() => new(os, new Store(Path.Combine(dir, "state.json")), new HiddenLedger(Path.Combine(dir, "hidden.json")), () => now);

    public void Dispose() { if (Directory.Exists(dir)) Directory.Delete(dir, true); }

    WindowInfo Info(FakePlatform.Win w) => os.Describe(w.Hwnd)!;

    /// <summary>Home (shown) with a terminal, Work with an editor (pid 2) and a browser (pid 3),
    /// left a while ago. K = 0 unless a test says otherwise.</summary>
    (WorkspaceManager m, Sleeper s, Workspace home, Workspace work, FakePlatform.Win code, FakePlatform.Win web) Setup(int awake = 0)
    {
        var term = os.Open(@"c:\term.exe", "Terminal", pid: 1);
        var code = os.Open(@"c:\code.exe", "TabStack", pid: 2);
        var web = os.Open(@"c:\chrome.exe", "Docs", pid: 3);
        var m = Manager();
        m.UpdateSettings(x => x.AwakeWorkspaces = awake);
        var home = m.Current;
        m.AddWindow(Info(term));
        var work = m.CreateWorkspace("Work");
        m.SwitchWorkspace(work.Id);
        m.AddWindow(Info(code));
        m.AddWindow(Info(web));
        m.SwitchWorkspace(home.Id);
        var s = new Sleeper(m, os, power, () => now);
        s.WakeDisplayed();
        return (m, s, home, work, code, web);
    }

    [Fact]
    public void AWorkspaceAwayLongEnoughSleepsAndWakesWhenShown()
    {
        var (m, s, home, work, _, _) = Setup();
        now += 14 * 60;
        s.Evaluate();
        Assert.Empty(power.Throttled);

        now += 2 * 60;
        s.Evaluate();
        Assert.Equal([2, 3], power.Throttled.Order());
        Assert.Equal(SleepLevel.Throttled, m.Find(work.Id)!.Sleep?.Level);
        Assert.DoesNotContain(1, power.Throttled); // the workspace on screen

        m.SwitchWorkspace(work.Id);
        s.WakeDisplayed();
        Assert.Empty(power.Throttled);
        Assert.Empty(m.Throttled);
        Assert.Null(m.Find(work.Id)!.Sleep);
    }

    [Fact]
    public void MostUsedPinnedAndNeverSleepWorkspacesStayAwake()
    {
        var (m, s, _, work, _, _) = Setup(awake: 2);
        now += 20 * 60;
        s.Evaluate();
        Assert.Empty(power.Throttled); // Work is among the two most used

        m.UpdateSettings(x => x.AwakeWorkspaces = 0);
        m.SetPinned(work.Id, true);
        s.Evaluate();
        Assert.Empty(power.Throttled);

        m.SetPinned(work.Id, false);
        m.SetNoSleep(work.Id, true);
        s.Evaluate();
        Assert.Empty(power.Throttled);

        m.SetNoSleep(work.Id, false);
        s.Evaluate();
        Assert.NotEmpty(power.Throttled);

        m.UpdateSettings(x => x.Sleep = false);
        s.Evaluate();
        Assert.Empty(power.Throttled);
    }

    [Fact]
    public void AProcessStillInUseIsNotThrottled()
    {
        var (m, s, home, _, code, _) = Setup();
        // Another window of the browser is on screen, and the editor is playing sound.
        os.Open(@"c:\chrome.exe", "Mail", pid: 3);
        power.Audio.Add(2);
        now += 20 * 60;
        s.Evaluate();
        Assert.Empty(power.Throttled);

        // Sound stops, the browser window goes: both may sleep now. Sound again wakes it.
        power.Audio.Clear();
        os.Close(os.Windows.First(w => w.Title == "Mail").Hwnd);
        s.Evaluate();
        Assert.Equal([2, 3], power.Throttled.Order());
        power.Audio.Add(2);
        s.Evaluate();
        Assert.Equal([3], power.Throttled);
    }

    [Fact]
    public void AWindowSharedWithAnAwakeWorkspaceKeepsItsProcessAwake()
    {
        var (m, s, home, work, code, _) = Setup();
        m.AddWindow(Info(code)); // the editor is also a tab of Home (shared)
        m.SwitchWorkspace(work.Id);
        m.SwitchWorkspace(home.Id);
        now += 20 * 60;
        s.Evaluate();
        Assert.Equal([3], power.Throttled);
    }

    [Fact]
    public void MemoryLowClosesReopenableWindowsAndShowingTheWorkspaceReopensThem()
    {
        var (m, s, home, work, code, web) = Setup();
        os.Get(code.Hwnd).Rect = new Rect(300, 200, 900, 700);
        now += 20 * 60;
        power.Load = 90;
        s.Evaluate();
        var tab = m.Find(work.Id)!.Tabs.Single(t => t.Name == "code");
        Assert.DoesNotContain(os.Windows, w => w.Hwnd == code.Hwnd); // closed
        Assert.Contains(os.Windows, w => w.Hwnd == web.Hwnd);       // a browser is not reopenable here
        Assert.Equal(@"e:\projects\TabStack", tab.Reopen?.Folder);
        Assert.NotNull(tab.Slept);

        now += 30;
        s.Evaluate();
        Assert.Null(tab.Hwnd);
        Assert.Equal(SleepLevel.Closed, m.Find(work.Id)!.Sleep?.Level);

        // Back to Work: the editor reopens on its folder and goes back where it was.
        power.Load = 40;
        m.SwitchWorkspace(work.Id);
        s.WakeDisplayed();
        Assert.Equal(1, power.Reopens);
        Assert.True(s.Reopening);
        s.Adopt();
        Assert.False(s.Reopening);
        Assert.Null(tab.Slept);
        Assert.NotNull(tab.Hwnd);
        Assert.Equal(new Rect(300, 200, 900, 700), os.Get(tab.Hwnd!.Value).Rect);
        Assert.True(os.Get(tab.Hwnd!.Value).Visible);
        Assert.Null(m.Find(work.Id)!.Sleep);
        s.WakeDisplayed();
        Assert.Equal(1, power.Reopens);
        Assert.Null(m.Find(work.Id)!.Sleep);
    }

    [Fact]
    public void AWindowReopenedAfterItsWorkspaceWasLeftIsHiddenAgain()
    {
        var (m, s, home, work, code, _) = Setup();
        now += 20 * 60;
        power.Load = 90;
        s.Evaluate();
        now += 30;
        s.Evaluate();
        var tab = m.Find(work.Id)!.Tabs.Single(t => t.Name == "code");

        // Clicking through: Work shown (reopen starts), then Home again before it appears.
        power.Load = 40;
        m.SwitchWorkspace(work.Id);
        s.WakeDisplayed();
        m.SwitchWorkspace(home.Id);
        s.Adopt();
        Assert.False(os.Get(tab.Hwnd!.Value).Visible);
    }

    [Fact]
    public void AWindowThatWontCloseIsLeftAsItWas()
    {
        var (m, s, _, work, code, _) = Setup();
        os.RefuseClose.Add(code.Hwnd); // asked whether to save
        now += 20 * 60;
        power.Load = 90;
        s.Evaluate();
        var tab = m.Find(work.Id)!.Tabs.Single(t => t.Name == "code");
        Assert.NotNull(tab.Slept);

        now += 60;
        power.Load = 40;
        s.Evaluate();
        Assert.Null(tab.Slept);
        Assert.Equal(code.Hwnd, tab.Hwnd);
    }

    [Fact]
    public void UnsavedEditorsAreNotClosed()
    {
        var (m, s, _, work, code, _) = Setup();
        os.Get(code.Hwnd).Title = "● TabStack";
        now += 20 * 60;
        power.Load = 90;
        s.Evaluate();
        Assert.Contains(os.Windows, w => w.Hwnd == code.Hwnd);
    }

    [Fact]
    public void ProcessesLeftThrottledByACrashAreGivenBack()
    {
        var (m, s, _, _, _, _) = Setup();
        now += 20 * 60;
        s.Evaluate();
        Assert.NotEmpty(power.Throttled);
        // TabStack was killed: the next one finds them in the saved state.
        var again = Manager();
        _ = new Sleeper(again, os, power, () => now);
        Assert.Empty(power.Throttled);
        Assert.Empty(again.Throttled);
    }
}
