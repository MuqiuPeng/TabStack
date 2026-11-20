using TabStack.Core;

namespace TabStack.Core.Tests;

public class LayoutTests
{
    static readonly MonitorInfo Left = new("L", new Rect(0, 0, 1920, 1080), new Rect(64, 0, 1856, 1040), 96, true);
    static readonly MonitorInfo Right4k = new("R", new Rect(1920, 0, 3840, 2160), new Rect(1920, 0, 3840, 2100), 192, false);

    static Placement P(Rect r, string mon, int dpi, PlacementState s = PlacementState.Normal) =>
        new() { State = s, NormalRect = r, ActualRect = r, Monitor = mon, Dpi = dpi, Visible = true };

    [Fact]
    public void UnchangedWhenMonitorAndDpiStillMatch()
    {
        var p = P(new Rect(2000, 100, 1600, 1200), "R", 192);
        Assert.Same(p, LayoutMath.Fit(p, [Left, Right4k]));
    }

    [Fact]
    public void MissingMonitorMovesWindowToNearestAndScalesByDpi()
    {
        // Saved on the 4K monitor at 200 %; only the 1080p monitor at 100 % is left.
        var p = P(new Rect(1920 + 200, 100, 1600, 1200), "R", 192);
        var f = LayoutMath.Fit(p, [Left]);
        Assert.Equal("L", f.Monitor);
        Assert.Equal(96, f.Dpi);
        Assert.Equal(800, f.NormalRect.W);
        Assert.Equal(600, f.NormalRect.H);
        Assert.True(f.NormalRect.X >= Left.WorkArea.X && f.NormalRect.Right() <= Left.WorkArea.Right());
        Assert.True(f.NormalRect.Bottom() <= Left.WorkArea.Bottom());
    }

    [Fact]
    public void WindowLargerThanWorkAreaIsClamped()
    {
        var p = P(new Rect(-5000, -5000, 5000, 4000), "gone", 96);
        var f = LayoutMath.Fit(p, [Left]);
        Assert.Equal(Left.WorkArea, f.NormalRect);
    }

    [Fact]
    public void MostlyOffScreenWindowIsPulledBackOnSameMonitor()
    {
        var p = P(new Rect(1800, 900, 800, 600), "L", 96);
        var f = LayoutMath.Fit(p, [Left]);
        Assert.Equal(new Rect(1920 - 800, 1040 - 600, 800, 600), f.NormalRect);
    }

    [Fact]
    public void SnappedUsesItsActualRectToChooseTheMonitor()
    {
        var p = P(new Rect(100, 100, 400, 300), "gone", 96, PlacementState.Snapped);
        p.ActualRect = new Rect(1920, 0, 1920, 2100);
        Assert.Equal("R", LayoutMath.Fit(p, [Left, Right4k]).Monitor);
    }
}

public sealed class AppIdTests
{
    [Theory]
    [InlineData(@"D:\ProgramFiles\miHoYo Launcher\1.19.0.382\HYP.exe", @"d:\programfiles\mihoyo launcher\*\hyp.exe")]
    [InlineData(@"D:\ProgramFiles\miHoYo Launcher\1.20.1.392\HYP.exe", @"d:\programfiles\mihoyo launcher\*\hyp.exe")]
    [InlineData(@"C:\Users\me\AppData\Local\Discord\app-1.0.9213\Discord.exe", @"c:\users\me\appdata\local\discord\*\discord.exe")]
    [InlineData(@"C:\Users\me\.claude-science\electron\42.10.0\claude-science.exe", @"c:\users\me\.claude-science\electron\*\claude-science.exe")]
    [InlineData(@"C:\Program Files\Steam\steam.exe", @"c:\program files\steam\steam.exe")]
    [InlineData(@"C:\Apps\Tool2\v3\tool.exe", @"c:\apps\tool2\v3\tool.exe")]
    [InlineData("Claude_pzs8sxrjxfjjc!Claude", "Claude_pzs8sxrjxfjjc!Claude")]
    public void VersionFoldersAreLeftOut(string exe, string id) => Assert.Equal(id, AppIds.FromExe(exe));

    [Fact]
    public void AnUpdatedAppIsFoundInItsNewFolder()
    {
        var root = Path.Combine(Path.GetTempPath(), "tabstack-appids-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "1.20.1.392"));
            File.WriteAllText(Path.Combine(root, "1.20.1.392", "HYP.exe"), "");
            Assert.Equal(Path.Combine(root, "1.20.1.392", "HYP.exe"), AppIds.Locate(Path.Combine(root, "1.19.0.382", "HYP.exe")));
            Assert.Null(AppIds.Locate(Path.Combine(root, "1.19.0.382", "Other.exe")));
        }
        finally { Directory.Delete(root, true); }
    }
}

public sealed class TicketScopeTests
{
    static Workspace Ws(string name, params string[] titles) =>
        new() { Name = name, Tabs = titles.Select(t => new AppTab { AppID = "x", Title = t }).ToList() };

    [Fact]
    public void AWorkspaceNamedLikeTheProjectHoldsIt() =>
        Assert.True(TicketScope.Holds(Ws("tabstack"), @"E:\projects\TabStack"));

    [Fact]
    public void WindowTitlesNamingTheFolderHoldIt()
    {
        Assert.True(TicketScope.Holds(Ws("Dev", "WorkspaceManager.cs - TabStack - Visual Studio Code"), @"E:\projects\TabStack"));
        Assert.True(TicketScope.Holds(Ws("Dev", @"pwsh: E:\projects\TicketDeck\src"), @"E:\projects\TicketDeck"));
        Assert.True(TicketScope.Holds(Ws("Dev", "TicketDeck"), @"E:\projects\TicketDeck\"));
    }

    [Fact]
    public void APartOfAnotherWordDoesNot()
    {
        Assert.False(TicketScope.Holds(Ws("Dev", "TabStackOverflow - Chrome"), @"E:\projects\TabStack"));
        Assert.False(TicketScope.Holds(Ws("Life", "微信", "Spotify"), @"E:\projects\TabStack"));
    }
}
