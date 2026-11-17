using System.Runtime.CompilerServices;
using TabStack.Core;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Dwm;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.HiDpi;
using Windows.Win32.UI.WindowsAndMessaging;
using CoreRect = TabStack.Core.Rect;

namespace TabStack.Platform.Windows;

/// <summary>Window placement, monitors and moving: the layout half of the platform.</summary>
public sealed unsafe partial class WindowsPlatform
{
    public void Minimize(long hwnd) => PInvoke.ShowWindow((HWND)(nint)hwnd, SHOW_WINDOW_CMD.SW_SHOWMINNOACTIVE);

    public Placement? GetPlacement(long handle)
    {
        var hwnd = (HWND)(nint)handle;
        if (!PInvoke.IsWindow(hwnd)) return null;
        var wp = new WINDOWPLACEMENT { length = (uint)sizeof(WINDOWPLACEMENT) };
        if (!PInvoke.GetWindowPlacement(hwnd, ref wp) || !PInvoke.GetWindowRect(hwnd, out var actual)) return null;

        var iconic = PInvoke.IsIconic(hwnd);
        var normal = WorkspaceToScreen(wp.rcNormalPosition);
        var state = iconic ? PlacementState.Minimized
                  : PInvoke.IsZoomed(hwnd) ? PlacementState.Maximized
                  : !SameRect(actual, normal) ? PlacementState.Snapped   // Aero Snap keeps the old normal rect
                  : PlacementState.Normal;
        var monitor = PInvoke.MonitorFromWindow(hwnd, MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST);
        return new Placement
        {
            State = state,
            NormalRect = ToCore(normal),
            ActualRect = iconic ? ToCore(normal) : ToCore(actual),
            Monitor = DescribeMonitor(monitor)?.Device,
            Dpi = (int)PInvoke.GetDpiForWindow(hwnd),
            Visible = PInvoke.IsWindowVisible(hwnd) && !iconic,
        };
    }

    public void ApplyLayout(IReadOnlyList<(long Hwnd, Placement Placement)> bottomToTop)
    {
        foreach (var (handle, p) in bottomToTop)
        {
            var hwnd = (HWND)(nint)handle;
            if (!PInvoke.IsWindow(hwnd)) continue;
            var normal = p.NormalRect;
            var state = p.State;
            if (!Resizable(hwnd))
            {
                // Fixed size: keep the size it has, only put it back where it was.
                if (PInvoke.GetWindowRect(hwnd, out var now) && !PInvoke.IsIconic(hwnd) && now.right > now.left)
                    normal = normal with { W = now.right - now.left, H = now.bottom - now.top };
                if (state is PlacementState.Maximized or PlacementState.Snapped) state = PlacementState.Normal;
            }
            var wp = new WINDOWPLACEMENT
            {
                length = (uint)sizeof(WINDOWPLACEMENT),
                rcNormalPosition = ScreenToWorkspace(FromCore(normal)),
                showCmd = state switch
                {
                    PlacementState.Minimized => SHOW_WINDOW_CMD.SW_SHOWMINNOACTIVE,
                    // There is no "maximize without activating"; the final activation and the
                    // stacking pass below put focus and order right.
                    PlacementState.Maximized => SHOW_WINDOW_CMD.SW_SHOWMAXIMIZED,
                    _ => SHOW_WINDOW_CMD.SW_SHOWNOACTIVATE,
                },
            };
            PInvoke.SetWindowPlacement(hwnd, in wp);
            if (state != PlacementState.Minimized) Repaint(handle);
            if (state == PlacementState.Snapped)
            {
                var r = p.ActualRect;
                PInvoke.SetWindowPos(hwnd, HWND.Null, r.X, r.Y, r.W, r.H,
                    SET_WINDOW_POS_FLAGS.SWP_NOZORDER | SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE);
            }
        }
        // Stacking: each one goes on top of the previous, so the last ends up highest.
        foreach (var (handle, p) in bottomToTop)
        {
            if (p.State == PlacementState.Minimized) continue;
            PInvoke.SetWindowPos((HWND)(nint)handle, HWND.Null, 0, 0, 0, 0,
                SET_WINDOW_POS_FLAGS.SWP_NOMOVE | SET_WINDOW_POS_FLAGS.SWP_NOSIZE | SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE);
        }
    }

    public IReadOnlyList<MonitorInfo> Monitors()
    {
        var list = new List<MonitorInfo>();
        PInvoke.EnumDisplayMonitors(default(HDC), (RECT?)null, (h, _, _, _) =>
        {
            if (DescribeMonitor(h) is { } m) list.Add(m);
            return true;
        }, 0);
        return list;
    }

    public void Raise(IReadOnlyList<long> bottomToTop)
    {
        foreach (var handle in bottomToTop)
            PInvoke.SetWindowPos((HWND)(nint)handle, HWND.Null, 0, 0, 0, 0,
                SET_WINDOW_POS_FLAGS.SWP_NOMOVE | SET_WINDOW_POS_FLAGS.SWP_NOSIZE | SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE);
    }

    /// <summary>Whether a window fills the whole of a monitor (taskbar included): a full-screen
    /// game or video, F11 in a browser. The desktop and the taskbar don't count.</summary>
    public bool CoversMonitor(long handle, CoreRect monitor)
    {
        var hwnd = (HWND)(nint)handle;
        if (handle == 0 || !PInvoke.IsWindow(hwnd) || !PInvoke.IsWindowVisible(hwnd) || PInvoke.IsIconic(hwnd)) return false;
        var cls = ClassName(hwnd);
        if (cls is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd") return false;
        uint pid;
        PInvoke.GetWindowThreadProcessId(hwnd, &pid);
        if (pid == Environment.ProcessId) return false;
        if (!PInvoke.GetWindowRect(hwnd, out var r)) return false;
        // Maximized windows overhang by their invisible border but stop at the work area; a
        // full-screen one covers the monitor's own bounds.
        RECT f;
        if (PInvoke.DwmGetWindowAttribute(hwnd, DWMWINDOWATTRIBUTE.DWMWA_EXTENDED_FRAME_BOUNDS, &f, (uint)sizeof(RECT)).Succeeded) r = f;
        return r.left <= monitor.X && r.top <= monitor.Y && r.right >= monitor.X + monitor.W && r.bottom >= monitor.Y + monitor.H;
    }

    public bool CloseWindow(long handle)
    {
        var hwnd = (HWND)(nint)handle;
        return PInvoke.IsWindow(hwnd) && PInvoke.PostMessage(hwnd, PInvoke.WM_CLOSE, default, default);
    }

    public double BootTime() =>
        DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0 - Environment.TickCount64 / 1000.0;

    public CoreRect WorkArea(long handle)
    {
        var monitor = handle != 0
            ? PInvoke.MonitorFromWindow((HWND)(nint)handle, MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST)
            : PInvoke.MonitorFromPoint(default, MONITOR_FROM_FLAGS.MONITOR_DEFAULTTOPRIMARY);
        return DescribeMonitor(monitor)?.WorkArea ?? default;
    }

    // Helpers

    static MonitorInfo? DescribeMonitor(HMONITOR monitor)
    {
        var mi = new MONITORINFOEXW();
        mi.monitorInfo.cbSize = (uint)sizeof(MONITORINFOEXW);
        if (!PInvoke.GetMonitorInfo(monitor, ref Unsafe.As<MONITORINFOEXW, MONITORINFO>(ref mi))) return null;
        PInvoke.GetDpiForMonitor(monitor, MONITOR_DPI_TYPE.MDT_EFFECTIVE_DPI, out var dpi, out _);
        var (id, name) = DisplayIds.For(mi.szDevice.ToString());
        return new MonitorInfo(id, ToCore(mi.monitorInfo.rcMonitor), ToCore(mi.monitorInfo.rcWork),
            (int)dpi, (mi.monitorInfo.dwFlags & 1) != 0, name);
    }

    /// <summary>rcNormalPosition is in workspace coordinates: relative to the work area of the
    /// monitor it lies on (taskbar and app bars excluded).</summary>
    static RECT WorkspaceToScreen(RECT r)
    {
        var (dx, dy) = WorkOffset(PInvoke.MonitorFromRect(r, MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST));
        return new RECT { left = r.left + dx, top = r.top + dy, right = r.right + dx, bottom = r.bottom + dy };
    }

    static RECT ScreenToWorkspace(RECT r)
    {
        var (dx, dy) = WorkOffset(PInvoke.MonitorFromRect(r, MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST));
        return new RECT { left = r.left - dx, top = r.top - dy, right = r.right - dx, bottom = r.bottom - dy };
    }

    static (int dx, int dy) WorkOffset(HMONITOR monitor)
    {
        var mi = new MONITORINFO { cbSize = (uint)sizeof(MONITORINFO) };
        if (!PInvoke.GetMonitorInfo(monitor, ref mi)) return (0, 0);
        return (mi.rcWork.left - mi.rcMonitor.left, mi.rcWork.top - mi.rcMonitor.top);
    }

    static bool SameRect(RECT a, RECT b) =>
        Math.Abs(a.left - b.left) <= 1 && Math.Abs(a.top - b.top) <= 1 && Math.Abs(a.right - b.right) <= 1 && Math.Abs(a.bottom - b.bottom) <= 1;

    static CoreRect ToCore(RECT r) => new(r.left, r.top, r.right - r.left, r.bottom - r.top);
    static RECT FromCore(CoreRect r) => new() { left = r.X, top = r.Y, right = r.X + r.W, bottom = r.Y + r.H };
}
