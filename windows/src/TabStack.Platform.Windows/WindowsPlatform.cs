using System.Diagnostics;
using System.Runtime.InteropServices;
using TabStack.Core;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Dwm;
using Windows.Win32.Security;
using Windows.Win32.System.Com.StructuredStorage;
using Windows.Win32.System.Threading;
using Windows.Win32.UI.Input.KeyboardAndMouse;
using Windows.Win32.UI.Shell.PropertiesSystem;
using Windows.Win32.UI.WindowsAndMessaging;

namespace TabStack.Platform.Windows;

/// <summary>Win32 implementation of <see cref="IWindowPlatform"/>.</summary>
public sealed unsafe partial class WindowsPlatform : IWindowPlatform
{
    readonly uint ownPid = (uint)Environment.ProcessId;
    readonly bool selfElevated = IsElevated(Process.GetCurrentProcess().SafeHandle);
    /// <summary>exe path → display name, so FileVersionInfo is read once per app.</summary>
    readonly Dictionary<string, string> appNames = new(StringComparer.OrdinalIgnoreCase);

    public IReadOnlyList<WindowInfo> EnumerateWindows()
    {
        var list = new List<WindowInfo>();
        PInvoke.EnumWindows((hwnd, _) =>
        {
            if (IsTaskbarWindow(hwnd) && Describe(hwnd) is { } info) list.Add(info);
            return true;
        }, 0);
        return list;
    }

    /// <summary>Visible, unowned (or WS_EX_APPWINDOW), not a tool window, not cloaked, titled,
    /// and not ours.</summary>
    bool IsTaskbarWindow(HWND hwnd)
    {
        if (!PInvoke.IsWindowVisible(hwnd)) return false;
        var ex = (WINDOW_EX_STYLE)PInvoke.GetWindowLong(hwnd, WINDOW_LONG_PTR_INDEX.GWL_EXSTYLE);
        if (ex.HasFlag(WINDOW_EX_STYLE.WS_EX_TOOLWINDOW)) return false;
        if (!ex.HasFlag(WINDOW_EX_STYLE.WS_EX_APPWINDOW) && !PInvoke.GetWindow(hwnd, GET_WINDOW_CMD.GW_OWNER).IsNull) return false;
        if (IsCloaked(hwnd)) return false;
        if (PInvoke.GetWindowTextLength(hwnd) == 0) return false;
        uint pid;
        PInvoke.GetWindowThreadProcessId(hwnd, &pid);
        return pid != ownPid;
    }

    static bool IsCloaked(HWND hwnd)
    {
        uint cloaked = 0;
        var hr = PInvoke.DwmGetWindowAttribute(hwnd, DWMWINDOWATTRIBUTE.DWMWA_CLOAKED, &cloaked, sizeof(uint));
        return hr.Succeeded && cloaked != 0;
    }

    public WindowInfo? Describe(long handle)
    {
        var hwnd = (HWND)(nint)handle;
        if (!PInvoke.IsWindow(hwnd)) return null;
        uint pid;
        PInvoke.GetWindowThreadProcessId(hwnd, &pid);
        if (pid == 0) return null;
        var cls = ClassName(hwnd);
        var appPid = pid;
        // UWP: the frame belongs to ApplicationFrameHost; the app is the CoreWindow inside.
        if (cls == "ApplicationFrameWindow" && CoreWindowPid(hwnd, pid) is { } inner) appPid = inner;

        var exe = ExePath(appPid);
        var aumid = WindowAumid(hwnd) ?? ProcessAumid(appPid);
        var appID = aumid ?? exe?.ToLowerInvariant() ?? $"pid:{appPid}";
        var title = Text(hwnd);
        return new WindowInfo(handle, appID, AppName(exe, aumid, title), title, cls, (int)appPid, exe,
            Locked: !selfElevated && IsLocked(appPid), Visible: PInvoke.IsWindowVisible(hwnd), Minimized: PInvoke.IsIconic(hwnd));
    }

    public ProcessStamp? Stamp(long handle)
    {
        var hwnd = (HWND)(nint)handle;
        if (!PInvoke.IsWindow(hwnd)) return null;
        uint pid;
        PInvoke.GetWindowThreadProcessId(hwnd, &pid);
        return StartTime(pid) is { } t ? new ProcessStamp((int)pid, t) : null;
    }

    public void Hide(long hwnd) => PInvoke.ShowWindow((HWND)(nint)hwnd, SHOW_WINDOW_CMD.SW_HIDE);

    public void Show(long hwnd) => PInvoke.ShowWindow((HWND)(nint)hwnd, SHOW_WINDOW_CMD.SW_SHOWNA);

    public bool Activate(long handle)
    {
        var hwnd = (HWND)(nint)handle;
        if (!PInvoke.IsWindow(hwnd)) return false;
        PInvoke.ShowWindow(hwnd, PInvoke.IsIconic(hwnd) ? SHOW_WINDOW_CMD.SW_RESTORE : SHOW_WINDOW_CMD.SW_SHOW);
        if (PInvoke.SetForegroundWindow(hwnd) && PInvoke.GetForegroundWindow() == hwnd) return true;
        // Foreground lock: a synthetic Alt press counts as input to us, which lifts it.
        TapAlt();
        PInvoke.SetForegroundWindow(hwnd);
        PInvoke.BringWindowToTop(hwnd);
        return PInvoke.GetForegroundWindow() == hwnd;
    }

    public long ForegroundWindow() => (nint)PInvoke.GetForegroundWindow();

    static void TapAlt()
    {
        Span<INPUT> inputs = stackalloc INPUT[2];
        inputs[0].type = INPUT_TYPE.INPUT_KEYBOARD;
        inputs[0].Anonymous.ki.wVk = VIRTUAL_KEY.VK_MENU;
        inputs[1].type = INPUT_TYPE.INPUT_KEYBOARD;
        inputs[1].Anonymous.ki.wVk = VIRTUAL_KEY.VK_MENU;
        inputs[1].Anonymous.ki.dwFlags = KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP;
        PInvoke.SendInput(inputs, sizeof(INPUT));
    }

    // ───────────────────────── Helpers ─────────────────────────

    static string Text(HWND hwnd)
    {
        var len = PInvoke.GetWindowTextLength(hwnd);
        if (len <= 0) return "";
        var buf = stackalloc char[len + 1];
        var n = PInvoke.GetWindowText(hwnd, buf, len + 1);
        return new string(buf, 0, n);
    }

    static string ClassName(HWND hwnd)
    {
        var buf = stackalloc char[256];
        var n = PInvoke.GetClassName(hwnd, buf, 256);
        return new string(buf, 0, n);
    }

    static uint? CoreWindowPid(HWND frame, uint framePid)
    {
        uint? found = null;
        PInvoke.EnumChildWindows(frame, (child, _) =>
        {
            uint pid;
            PInvoke.GetWindowThreadProcessId(child, &pid);
            if (pid != framePid && ClassName(child) == "Windows.UI.Core.CoreWindow") { found = pid; return false; }
            return true;
        }, 0);
        return found;
    }

    static string? ExePath(uint pid)
    {
        using var h = OpenQuery(pid);
        if (h is null) return null;
        var buf = stackalloc char[1024];
        uint size = 1024;
        return PInvoke.QueryFullProcessImageName(h, PROCESS_NAME_FORMAT.PROCESS_NAME_WIN32, buf, ref size)
            ? new string(buf, 0, (int)size) : null;
    }

    static long? StartTime(uint pid)
    {
        using var h = OpenQuery(pid);
        if (h is null) return null;
        return PInvoke.GetProcessTimes(h, out var c, out _, out _, out _)
            ? ((long)(uint)c.dwHighDateTime << 32) | (uint)c.dwLowDateTime : null;
    }

    static SafeHandle? OpenQuery(uint pid)
    {
        var h = PInvoke.OpenProcess_SafeHandle(PROCESS_ACCESS_RIGHTS.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (!h.IsInvalid) return h;
        h.Dispose();
        return null;
    }

    /// <summary>Elevated (or otherwise beyond our reach): UIPI blocks hiding and moving it.</summary>
    static bool IsLocked(uint pid)
    {
        using var h = OpenQuery(pid);
        return h is null || IsElevated(h);
    }

    static bool IsElevated(SafeHandle process)
    {
        if (!PInvoke.OpenProcessToken(process, TOKEN_ACCESS_MASK.TOKEN_QUERY, out var token)) return true;
        using (token)
        {
            TOKEN_ELEVATION elevation;
            return PInvoke.GetTokenInformation(token, TOKEN_INFORMATION_CLASS.TokenElevation, &elevation, (uint)sizeof(TOKEN_ELEVATION), out _)
                   && elevation.TokenIsElevated != 0;
        }
    }

    /// <summary>The AppUserModelID set on the window itself (PWAs, browser profiles, UWP frames).</summary>
    static string? WindowAumid(HWND hwnd)
    {
        object? obj = null;
        try
        {
            if (PInvoke.SHGetPropertyStoreForWindow(hwnd, typeof(IPropertyStore).GUID, out obj).Failed) return null;
            if (obj is not IPropertyStore store) return null;
            store.GetValue(PInvoke.PKEY_AppUserModel_ID, out var pv);
            try
            {
                return pv.Anonymous.Anonymous.vt == global::Windows.Win32.System.Variant.VARENUM.VT_LPWSTR
                    ? pv.Anonymous.Anonymous.Anonymous.pwszVal.ToString() : null;
            }
            finally { PInvoke.PropVariantClear(ref pv); }
        }
        catch (COMException) { return null; }
        finally { if (obj is not null) Marshal.ReleaseComObject(obj); }
    }

    /// <summary>Packaged apps have an AUMID on the process.</summary>
    static string? ProcessAumid(uint pid)
    {
        using var h = OpenQuery(pid);
        if (h is null) return null;
        uint len = 256;
        var buf = stackalloc char[256];
        return PInvoke.GetApplicationUserModelId(h, ref len, buf) == WIN32_ERROR.ERROR_SUCCESS
            ? new string(buf, 0, (int)Math.Max(0, len - 1)) : null;
    }

    string AppName(string? exe, string? aumid, string title)
    {
        if (exe is null) return aumid ?? title;
        if (appNames.TryGetValue(exe, out var name)) return name;
        try
        {
            var v = FileVersionInfo.GetVersionInfo(exe);
            // Electron apps often keep the framework's description; their product name is the app.
            var description = v.FileDescription?.Trim();
            if (description is "Electron" or "") description = null;
            name = description ?? (!string.IsNullOrWhiteSpace(v.ProductName) && v.ProductName.Trim() != "Electron" ? v.ProductName.Trim() : null)
                   ?? Path.GetFileNameWithoutExtension(exe);
        }
        catch (FileNotFoundException) { name = Path.GetFileNameWithoutExtension(exe); }
        // UWP host processes say nothing useful; the window title names the app.
        if (exe.EndsWith("ApplicationFrameHost.exe", StringComparison.OrdinalIgnoreCase)) return title;
        appNames[exe] = name;
        return name;
    }

}
