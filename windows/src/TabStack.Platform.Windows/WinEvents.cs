using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.Accessibility;
using Windows.Win32.UI.WindowsAndMessaging;

namespace TabStack.Platform.Windows;

/// <summary>
/// Out-of-context WinEvent hooks. Callbacks arrive on the thread that created this object,
/// which must pump messages (the WPF UI thread does).
/// </summary>
public sealed class WinEvents : IDisposable
{
    readonly List<HWINEVENTHOOK> hooks = new();
    readonly WINEVENTPROC proc; // kept alive: the OS holds only a raw pointer

    /// <summary>A window became the foreground window.</summary>
    public event Action<long>? Foreground;
    /// <summary>A top-level window's title changed.</summary>
    public event Action<long>? TitleChanged;
    /// <summary>A top-level window was destroyed.</summary>
    public event Action<long>? Destroyed;
    /// <summary>A top-level window was shown.</summary>
    public event Action<long>? Shown;
    /// <summary>A window finished moving or resizing, or was minimized or restored.</summary>
    public event Action<long>? LayoutChanged;

    public WinEvents()
    {
        proc = Callback;
        Hook(PInvoke.EVENT_SYSTEM_FOREGROUND, PInvoke.EVENT_SYSTEM_FOREGROUND);
        Hook(PInvoke.EVENT_OBJECT_DESTROY, PInvoke.EVENT_OBJECT_SHOW);
        Hook(PInvoke.EVENT_OBJECT_NAMECHANGE, PInvoke.EVENT_OBJECT_NAMECHANGE);
        Hook(PInvoke.EVENT_SYSTEM_MOVESIZEEND, PInvoke.EVENT_SYSTEM_MOVESIZEEND);
        Hook(PInvoke.EVENT_SYSTEM_MINIMIZESTART, PInvoke.EVENT_SYSTEM_MINIMIZEEND);
        // Snap, maximize and keyboard moves end without MOVESIZEEND; location changes catch them.
        Hook(PInvoke.EVENT_OBJECT_LOCATIONCHANGE, PInvoke.EVENT_OBJECT_LOCATIONCHANGE);
    }

    void Hook(uint min, uint max)
    {
        var h = PInvoke.SetWinEventHook(min, max, HINSTANCE.Null, proc, 0, 0,
            PInvoke.WINEVENT_OUTOFCONTEXT | PInvoke.WINEVENT_SKIPOWNPROCESS);
        if (!h.IsNull) hooks.Add(h);
    }

    void Callback(HWINEVENTHOOK hook, uint ev, HWND hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (hwnd.IsNull || idObject != (int)OBJECT_IDENTIFIER.OBJID_WINDOW || idChild != (int)PInvoke.CHILDID_SELF) return;
        var h = (long)(nint)hwnd;
        switch (ev)
        {
            case PInvoke.EVENT_SYSTEM_FOREGROUND: Foreground?.Invoke(h); break;
            case PInvoke.EVENT_OBJECT_NAMECHANGE: TitleChanged?.Invoke(h); break;
            case PInvoke.EVENT_OBJECT_DESTROY: Destroyed?.Invoke(h); break;
            case PInvoke.EVENT_OBJECT_SHOW: Shown?.Invoke(h); break;
            case PInvoke.EVENT_SYSTEM_MOVESIZEEND:
            case PInvoke.EVENT_SYSTEM_MINIMIZESTART:
            case PInvoke.EVENT_SYSTEM_MINIMIZEEND:
            case PInvoke.EVENT_OBJECT_LOCATIONCHANGE: LayoutChanged?.Invoke(h); break;
        }
    }

    public void Dispose()
    {
        foreach (var h in hooks) PInvoke.UnhookWinEvent(h);
        hooks.Clear();
    }
}
