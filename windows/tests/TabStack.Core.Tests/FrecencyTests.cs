using TabStack.Core;

namespace TabStack.Core.Tests;

public class FrecencyTests
{
    const double Now = 1_700_000_000;

    static Workspace Ws(string name, params double[] agoDays) =>
        new() { Name = name, Usage = agoDays.Select(d => Now - d * 86400).ToList() };

    [Fact]
    public void UseWeightHalvesEveryHalfLife()
    {
        Assert.Equal(1, Frecency.Score(Ws("a", 0), Now), 6);
        Assert.Equal(0.5, Frecency.Score(Ws("a", 3), Now), 6);
        Assert.Equal(0.25, Frecency.Score(Ws("a", 6), Now), 6);
        Assert.Equal(0, Frecency.Score(new Workspace(), Now));
    }

    [Fact]
    public void FutureUsesCountAsNow() => Assert.Equal(1, Frecency.Score(Ws("a", -1), Now), 6);

    [Fact]
    public void RecordUseKeepsOnlyTheNewest()
    {
        var ws = new Workspace();
        for (var i = 0; i < Frecency.Keep + 5; i++) Frecency.RecordUse(ws, i);
        Assert.Equal(Frecency.Keep, ws.Usage!.Count);
        Assert.Equal(5, ws.Usage[0]);
    }

    [Theory]
    [InlineData("web", 10)]
    [InlineData("we", 8)]
    [InlineData("shop", 6)]
    [InlineData("eb sh", 5)]
    [InlineData("wsp", 2.5)]
    [InlineData("zzz", 0)]
    public void MatchRanksPrefixOverWordOverSubstring(string q, double expected)
    {
        var ws = new Workspace { Name = q == "web" ? "Web" : "Web shop" };
        Assert.Equal(expected, Frecency.Match(q, ws), 6);
    }

    [Fact]
    public void MatchFallsBackToTabTitles()
    {
        var ws = new Workspace { Name = "Work", Tabs = [new AppTab { Name = "Chrome", Title = "Inbox - Gmail" }] };
        Assert.Equal(1.5, Frecency.Match("gmail", ws));
    }

    [Fact]
    public void ActiveTakesCurrentPinnedThenFrecency()
    {
        var a = Ws("a"); var b = Ws("b", 0, 0); var c = Ws("c", 0); var d = Ws("d", 10); var e = Ws("e");
        e.Pinned = true;
        var list = new[] { a, b, c, d, e };
        var active = Frecency.Active(list, a.Id, [], 3, Now);
        Assert.Equal(new HashSet<Guid> { a.Id, e.Id, b.Id }, active);
    }

    [Fact]
    public void SearchWithoutQueryOrdersByFrecency()
    {
        var a = Ws("alpha", 9); var b = Ws("beta", 0); var c = Ws("gamma", 3);
        Assert.Equal(["beta", "gamma", "alpha"], Frecency.Search([a, b, c], "", Now).Select(w => w.Name));
        Assert.Equal(["alpha"], Frecency.Search([a, b, c], "alp", Now).Select(w => w.Name));
    }
}
