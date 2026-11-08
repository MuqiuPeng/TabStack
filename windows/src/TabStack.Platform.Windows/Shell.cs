using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.UI.HiDpi;
using Windows.Win32.UI.Input.KeyboardAndMouse;
using Windows.Win32.UI.Shell;
using Windows.Win32.UI.WindowsAndMessaging;

namespace TabStack.Platform.Windows;

/// <summary>
/// Docks a window to the left edge of a monitor as an application desktop toolbar, so the
/// shell shrinks the work area and maximized windows stay clear of it.
/// Forward the window's messages to <see cref="WndProc"/>.
/// </summary>
public sealed class AppBar : IDisposable
{
    readonly HWND hwnd;
    bool registered;
    int widthDip;
    Core.Rect? monitorBounds;

    public uint CallbackMessage { get; }
    /// <summary>A full-screen app opened (true) or closed (false) on this monitor.</summary>
    public event Action<bool>? FullScreenChanged;

    public AppBar(nint handle)
    {
        hwnd = (HWND)handle;
        CallbackMessage = PInvoke.RegisterWindowMessage("TabStackAppBar");
    }

    unsafe APPBARDATA Data() => new()
    {
        cbSize = (uint)sizeof(APPBARDATA),
        hWnd = hwnd,
        uCallbackMessage = CallbackMessage,
        uEdge = PInvoke.ABE_LEFT,
    };

    /// <summary>Docks (or re-docks after a display change) to the left edge of the monitor
    /// whose bounds are given (physical pixels), or the primary one.</summary>
    public void Dock(int widthDip, Core.Rect? monitorBounds = null)
    {
        this.widthDip = widthDip;
        this.monitorBounds = monitorBounds;
        var data = Data();
        if (!registered)
        {
            PInvoke.SHAppBarMessage(PInvoke.ABM_NEW, ref data);
            registered = true;
        }
        var monitor = monitorBounds is { } b
            ? PInvoke.MonitorFromRect(new RECT { left = b.X, top = b.Y, right = b.X + b.W, bottom = b.Y + b.H }, MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST)
            : PInvoke.MonitorFromPoint(new System.Drawing.Point(0, 0), MONITOR_FROM_FLAGS.MONITOR_DEFAULTTOPRIMARY);
        var info = new MONITORINFO { cbSize = (uint)Marshal.SizeOf<MONITORINFO>() };
        PInvoke.GetMonitorInfo(monitor, ref info);
        PInvoke.GetDpiForMonitor(monitor, MONITOR_DPI_TYPE.MDT_EFFECTIVE_DPI, out var dpi, out _);
        var width = (int)Math.Round(widthDip * dpi / 96.0);

        var m = info.rcMonitor;
        data.rc = new RECT { left = m.left, top = m.top, right = m.left + width, bottom = m.bottom };
        PInvoke.SHAppBarMessage(PInvoke.ABM_QUERYPOS, ref data);
        // The shell may have moved our left edge right (another bar is docked there).
        data.rc.right = data.rc.left + width;
        PInvoke.SHAppBarMessage(PInvoke.ABM_SETPOS, ref data);
        PInvoke.SetWindowPos(hwnd, (HWND)(nint)(-1), data.rc.left, data.rc.top,
            data.rc.right - data.rc.left, data.rc.bottom - data.rc.top, SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE);
    }

    /// <summary>Returns true when the message was the app-bar callback.</summary>
    public bool WndProc(uint msg, nint wParam, nint lParam)
    {
        if (msg != CallbackMessage) return false;
        switch ((uint)wParam)
        {
            case PInvoke.ABN_POSCHANGED: Dock(widthDip, monitorBounds); break;
            case PInvoke.ABN_FULLSCREENAPP: FullScreenChanged?.Invoke(lParam != 0); break;
        }
        return true;
    }

    public void Dispose()
    {
        if (!registered) return;
        var data = Data();
        PInvoke.SHAppBarMessage(PInvoke.ABM_REMOVE, ref data);
        registered = false;
    }
}

/// <summary>Window styles for the sidebar: no Alt+Tab entry, never takes focus on click.</summary>
public static class SidebarStyle
{
    public static void Apply(nint handle)
    {
        var hwnd = (HWND)handle;
        var ex = (WINDOW_EX_STYLE)PInvoke.GetWindowLong(hwnd, WINDOW_LONG_PTR_INDEX.GWL_EXSTYLE);
        ex |= WINDOW_EX_STYLE.WS_EX_TOOLWINDOW | WINDOW_EX_STYLE.WS_EX_NOACTIVATE;
        ex &= ~WINDOW_EX_STYLE.WS_EX_APPWINDOW;
        PInvoke.SetWindowLong(hwnd, WINDOW_LONG_PTR_INDEX.GWL_EXSTYLE, (int)ex);
    }

    public static void SetTopmost(nint handle, bool topmost) =>
        PInvoke.SetWindowPos((HWND)handle, topmost ? (HWND)(nint)(-1) : (HWND)(nint)1, 0, 0, 0, 0,
            SET_WINDOW_POS_FLAGS.SWP_NOMOVE | SET_WINDOW_POS_FLAGS.SWP_NOSIZE | SET_WINDOW_POS_FLAGS.SWP_NOACTIVATE);
}

[Flags]
public enum Modifiers : uint { Alt = 1, Control = 2, Shift = 4, Win = 8 }

/// <summary>System-wide hotkeys (RegisterHotKey) delivered to a window as WM_HOTKEY.</summary>
public sealed class HotKeys : IDisposable
{
    readonly HWND hwnd;
    readonly Dictionary<int, Action> actions = new();
    int nextId = 1;

    public HotKeys(nint handle) => hwnd = (HWND)handle;

    /// <summary>Returns false when another app already holds the combination.</summary>
    public bool Register(Modifiers mods, int virtualKey, Action action)
    {
        var id = nextId++;
        if (!PInvoke.RegisterHotKey(hwnd, id, (HOT_KEY_MODIFIERS)mods | HOT_KEY_MODIFIERS.MOD_NOREPEAT, (uint)virtualKey))
            return false;
        actions[id] = action;
        return true;
    }

    public bool WndProc(uint msg, nint wParam)
    {
        if (msg != PInvoke.WM_HOTKEY) return false;
        if (actions.TryGetValue((int)wParam, out var a)) a();
        return true;
    }

    public void Dispose()
    {
        foreach (var id in actions.Keys) PInvoke.UnregisterHotKey(hwnd, id);
        actions.Clear();
    }
}
