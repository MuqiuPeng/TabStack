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

    [Fact]
    public void TileSplitsWorkArea()
    {
        var w = new Rect(64, 0, 1857, 1040);
        Assert.Equal(new Rect(64, 0, 928, 1040), LayoutMath.Tile(w, -1));
        Assert.Equal(new Rect(992, 0, 929, 1040), LayoutMath.Tile(w, 1));
        Assert.Equal(w, LayoutMath.Tile(w, 0));
    }
}
