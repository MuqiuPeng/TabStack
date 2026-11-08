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
            var wp = new WINDOWPLACEMENT
            {
                length = (uint)sizeof(WINDOWPLACEMENT),
                rcNormalPosition = ScreenToWorkspace(FromCore(p.NormalRect)),
                showCmd = p.State switch
                {
                    PlacementState.Minimized => SHOW_WINDOW_CMD.SW_SHOWMINNOACTIVE,
                    // There is no "maximize without activating"; the final activation and the
                    // stacking pass below put focus and order right.
                    PlacementState.Maximized => SHOW_WINDOW_CMD.SW_SHOWMAXIMIZED,
                    _ => SHOW_WINDOW_CMD.SW_SHOWNOACTIVATE,
                },
            };
            PInvoke.SetWindowPlacement(hwnd, in wp);
            if (p.State == PlacementState.Snapped)
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

    public void MoveTo(long handle, CoreRect rect)
    {
        var hwnd = (HWND)(nint)handle;
        if (!PInvoke.IsWindow(hwnd)) return;
        if (PInvoke.IsIconic(hwnd) || PInvoke.IsZoomed(hwnd)) PInvoke.ShowWindow(hwnd, SHOW_WINDOW_CMD.SW_RESTORE);
        // Windows 10/11 frames have invisible resize borders: the window rect is larger than
        // what you see. Grow the target by those margins so the visible frame fills it.
        PInvoke.GetWindowRect(hwnd, out var outer);
        RECT frame;
        int l = 0, t = 0, r = 0, b = 0;
        if (PInvoke.DwmGetWindowAttribute(hwnd, DWMWINDOWATTRIBUTE.DWMWA_EXTENDED_FRAME_BOUNDS, &frame, (uint)sizeof(RECT)).Succeeded)
        {
            l = frame.left - outer.left; t = frame.top - outer.top;
            r = outer.right - frame.right; b = outer.bottom - frame.bottom;
        }
        PInvoke.SetWindowPos(hwnd, HWND.Null, rect.X - l, rect.Y - t, rect.W + l + r, rect.H + t + b,
            SET_WINDOW_POS_FLAGS.SWP_NOZORDER | SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE);
    }

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
