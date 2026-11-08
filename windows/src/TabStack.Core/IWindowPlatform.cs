namespace TabStack.Core;

/// <summary>A top-level window as the platform sees it.</summary>
public sealed record WindowInfo(
    long Hwnd,
    /// <summary>AUMID if any, otherwise the exe path in lower case.</summary>
    string AppID,
    string AppName,
    string Title,
    string? ClassName,
    int Pid,
    string? ExePath,
    /// <summary>Elevated (UIPI): we cannot move, hide or close it.</summary>
    bool Locked,
    bool Visible,
    bool Minimized);

/// <summary>Identifies a process across pid reuse.</summary>
public readonly record struct ProcessStamp(int Pid, long StartTime);

/// <summary>Everything the workspace logic needs from the OS. The Windows implementation lives
/// in TabStack.Platform.Windows; tests use a fake.</summary>
public interface IWindowPlatform
{
    /// <summary>Taskbar-level windows (visible, unowned, not tool windows, not cloaked, titled),
    /// in Z order from top to bottom. Excludes TabStack's own windows.</summary>
    IReadOnlyList<WindowInfo> EnumerateWindows();

    /// <summary>The window if it still exists, whether shown or hidden; null when gone.</summary>
    WindowInfo? Describe(long hwnd);

    ProcessStamp? Stamp(long hwnd);

    /// <summary>Hide without activating anything (SW_HIDE).</summary>
    void Hide(long hwnd);

    /// <summary>Show in its current state (SW_SHOWNA): a minimized window stays minimized.</summary>
    void Show(long hwnd);

    /// <summary>Show, restore if minimized and bring to the foreground.</summary>
    bool Activate(long hwnd);

    long ForegroundWindow();

    /// <summary>Minimize without activating anything (SW_SHOWMINNOACTIVE).</summary>
    void Minimize(long hwnd);

    /// <summary>Where the window is and how it is shown, in screen coordinates; null when gone.</summary>
    Placement? GetPlacement(long hwnd);

    /// <summary>Applies placements and stacking order. <paramref name="bottomToTop"/> lists the
    /// windows from the bottom of the stack up; none is activated.</summary>
    void ApplyLayout(IReadOnlyList<(long Hwnd, Placement Placement)> bottomToTop);

    IReadOnlyList<MonitorInfo> Monitors();

    /// <summary>Moves a window so its visible frame fills <paramref name="rect"/> (restoring it
    /// first if maximized or minimized).</summary>
    void MoveTo(long hwnd, Rect rect);

    /// <summary>Work area of the monitor the window is on (the primary one if unknown).</summary>
    Rect WorkArea(long hwnd);
}
