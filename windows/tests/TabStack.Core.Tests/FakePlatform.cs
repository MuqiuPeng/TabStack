using TabStack.Core;

namespace TabStack.Core.Tests;

/// <summary>An in-memory desktop: a Z-ordered list of windows that can be hidden and shown.</summary>
sealed class FakePlatform : IWindowPlatform
{
    public sealed class Win
    {
        public long Hwnd;
        public string AppID = "";
        public string Title = "";
        public int Pid;
        public long Start = 1;
        public bool Visible = true;
        public bool Minimized;
        public bool Locked;
        public PlacementState State = PlacementState.Normal;
        public Rect Rect = new(100, 100, 800, 600);
    }

    public List<MonitorInfo> MonitorList = [new("DISPLAY1", new Rect(0, 0, 1920, 1080), new Rect(64, 0, 1856, 1040), 96, true)];
    public List<long> LastLayout = new();

    public readonly List<Win> Windows = new(); // top first
    public long Foreground;
    long next = 100;

    public Win Open(string app, string title, int pid = 1)
    {
        var w = new Win { Hwnd = next++, AppID = app, Title = title, Pid = pid };
        Windows.Insert(0, w);
        Foreground = w.Hwnd;
        return w;
    }

    public void Close(long hwnd) => Windows.RemoveAll(w => w.Hwnd == hwnd);

    public Win Get(long hwnd) => Windows.Single(w => w.Hwnd == hwnd);

    static WindowInfo Info(Win w) => new(w.Hwnd, w.AppID, Path.GetFileNameWithoutExtension(w.AppID), w.Title,
        "Cls", w.Pid, w.AppID, w.Locked, w.Visible, w.Minimized);

    public IReadOnlyList<WindowInfo> EnumerateWindows() => Windows.Where(w => w.Visible).Select(Info).ToList();
    public WindowInfo? Describe(long hwnd) => Windows.FirstOrDefault(w => w.Hwnd == hwnd) is { } w ? Info(w) : null;
    public ProcessStamp? Stamp(long hwnd) => Windows.FirstOrDefault(w => w.Hwnd == hwnd) is { } w ? new ProcessStamp(w.Pid, w.Start) : null;
    public void Hide(long hwnd) => Get(hwnd).Visible = false;
    public void Show(long hwnd) => Get(hwnd).Visible = true;

    public bool Activate(long hwnd)
    {
        var w = Get(hwnd);
        w.Visible = true;
        w.Minimized = false;
        if (w.State == PlacementState.Minimized) w.State = PlacementState.Normal;
        Windows.Remove(w);
        Windows.Insert(0, w);
        Foreground = hwnd;
        return true;
    }

    public long ForegroundWindow() => Foreground;

    public void Minimize(long hwnd) { var w = Get(hwnd); w.Minimized = true; w.State = PlacementState.Minimized; }

    public Placement? GetPlacement(long hwnd) => Windows.FirstOrDefault(w => w.Hwnd == hwnd) is { } w
        ? new Placement { State = w.State, NormalRect = w.Rect, ActualRect = w.Rect, Monitor = MonitorList[0].Device, Dpi = 96, Visible = w.Visible && !w.Minimized }
        : null;

    public void ApplyLayout(IReadOnlyList<(long Hwnd, Placement Placement)> bottomToTop)
    {
        LastLayout = bottomToTop.Select(x => x.Hwnd).ToList();
        foreach (var (h, p) in bottomToTop)
        {
            var w = Get(h);
            w.Visible = true;
            w.State = p.State;
            w.Minimized = p.State == PlacementState.Minimized;
            w.Rect = p.State == PlacementState.Snapped ? p.ActualRect : p.NormalRect;
            Windows.Remove(w);
            Windows.Insert(0, w);
        }
    }

    public IReadOnlyList<MonitorInfo> Monitors() => MonitorList;

    public void MoveTo(long hwnd, Rect rect) { var w = Get(hwnd); w.Rect = rect; w.State = PlacementState.Normal; w.Minimized = false; }

    public Rect WorkArea(long hwnd) => MonitorList[0].WorkArea;
}
