using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using TabStack.Core;

namespace TabStack.Platform.Windows;

/// <summary>Win32 side of sleeping (docs/windows-port.md §6): efficiency mode, sound, memory,
/// and reopen recipes for VS Code and File Explorer windows. Call from the UI (STA) thread:
/// File Explorer's windows are read through the shell's COM objects.</summary>
public sealed class WindowsSleep : ISleepPlatform
{
    // ───────────────────────── Efficiency mode ─────────────────────────

    const uint PROCESS_SET_INFORMATION = 0x0200, PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    const uint IDLE_PRIORITY_CLASS = 0x40;
    const int ProcessPowerThrottling = 4;
    const uint PROCESS_POWER_THROTTLING_EXECUTION_SPEED = 1;

    [StructLayout(LayoutKind.Sequential)]
    struct PowerThrottlingState { public uint Version, ControlMask, StateMask; }

    [DllImport("kernel32.dll", SetLastError = true)] static extern nint OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(nint h);
    [DllImport("kernel32.dll")] static extern bool SetProcessInformation(nint h, int cls, ref PowerThrottlingState info, int size);
    [DllImport("kernel32.dll")] static extern uint GetPriorityClass(nint h);
    [DllImport("kernel32.dll")] static extern bool SetPriorityClass(nint h, uint cls);
    [DllImport("kernel32.dll")] static extern bool GetProcessTimes(nint h, out long creation, out long exit, out long kernel, out long user);

    /// <summary>Efficiency mode as Task Manager shows it: EcoQoS plus idle priority.</summary>
    public IReadOnlyList<ThrottledProcess> Throttle(int pid)
    {
        var done = new List<ThrottledProcess>();
        foreach (var p in Tree(pid))
        {
            var h = OpenProcess(PROCESS_SET_INFORMATION | PROCESS_QUERY_LIMITED_INFORMATION, false, p);
            if (h == 0) { if (p == pid) return done; continue; }
            try
            {
                if (!GetProcessTimes(h, out var start, out _, out _, out _)) continue;
                var priority = GetPriorityClass(h);
                var state = new PowerThrottlingState { Version = 1, ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED, StateMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED };
                var eco = SetProcessInformation(h, ProcessPowerThrottling, ref state, Marshal.SizeOf<PowerThrottlingState>());
                var idle = SetPriorityClass(h, IDLE_PRIORITY_CLASS);
                if (eco || idle) done.Add(new ThrottledProcess(pid, p, start, (int)priority));
                else if (p == pid) return done;
            }
            finally { CloseHandle(h); }
        }
        return done;
    }

    public void Unthrottle(ThrottledProcess p)
    {
        var h = OpenProcess(PROCESS_SET_INFORMATION | PROCESS_QUERY_LIMITED_INFORMATION, false, p.Pid);
        if (h == 0) return;
        try
        {
            // Another process that got the pid since: leave it alone.
            if (!GetProcessTimes(h, out var start, out _, out _, out _) || start != p.Start) return;
            // No control bits: the system decides again, as for any process.
            var state = new PowerThrottlingState { Version = 1 };
            SetProcessInformation(h, ProcessPowerThrottling, ref state, Marshal.SizeOf<PowerThrottlingState>());
            if (p.Priority != 0) SetPriorityClass(h, (uint)p.Priority);
        }
        finally { CloseHandle(h); }
    }

    // ───────────────────────── Process tree ─────────────────────────

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct ProcessEntry
    {
        public uint dwSize, cntUsage, th32ProcessID;
        public nint th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)] static extern nint CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(nint snap, ref ProcessEntry e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(nint snap, ref ProcessEntry e);

    static long? StartTime(int pid)
    {
        var h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == 0) return null;
        try { return GetProcessTimes(h, out var s, out _, out _, out _) ? s : null; }
        finally { CloseHandle(h); }
    }

    /// <summary>A process and its descendants (children started after it: a reused parent pid
    /// doesn't make a stranger a child).</summary>
    static List<int> Tree(int root)
    {
        var children = new Dictionary<int, List<int>>();
        var snap = CreateToolhelp32Snapshot(0x2 /* TH32CS_SNAPPROCESS */, 0);
        if (snap is 0 or -1) return [root];
        try
        {
            var e = new ProcessEntry { dwSize = (uint)Marshal.SizeOf<ProcessEntry>() };
            for (var ok = Process32FirstW(snap, ref e); ok; ok = Process32NextW(snap, ref e))
            {
                if (e.th32ProcessID == 0 || e.th32ProcessID == e.th32ParentProcessID) continue;
                var parent = (int)e.th32ParentProcessID;
                if (!children.TryGetValue(parent, out var list)) children[parent] = list = new();
                list.Add((int)e.th32ProcessID);
            }
        }
        finally { CloseHandle(snap); }
        var result = new List<int> { root };
        var starts = new Dictionary<int, long?> { [root] = StartTime(root) };
        for (var i = 0; i < result.Count && result.Count < 500; i++)
        {
            if (!children.TryGetValue(result[i], out var kids)) continue;
            foreach (var k in kids)
            {
                var ks = StartTime(k);
                if (ks is null || starts[result[i]] is not { } ps || ks < ps || starts.ContainsKey(k)) continue;
                starts[k] = ks;
                result.Add(k);
            }
        }
        return result;
    }

    // ───────────────────────── Sound ─────────────────────────

    HashSet<int>? audioPids;
    DateTime audioAt;

    public bool PlayingAudio(int pid)
    {
        if (audioPids is null || DateTime.UtcNow - audioAt > TimeSpan.FromSeconds(2))
        {
            audioPids = Audio.ActivePids();
            audioAt = DateTime.UtcNow;
        }
        return audioPids.Count > 0 && Tree(pid).Any(audioPids.Contains);
    }

    // ───────────────────────── Memory ─────────────────────────

    [StructLayout(LayoutKind.Sequential)]
    struct MemoryStatusEx
    {
        public uint dwLength, dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx m);

    public int MemoryLoad()
    {
        var m = new MemoryStatusEx { dwLength = (uint)Marshal.SizeOf<MemoryStatusEx>() };
        return GlobalMemoryStatusEx(ref m) ? (int)m.dwMemoryLoad : 0;
    }

    // ───────────────────────── Reopen recipes ─────────────────────────

    /// <summary>VS Code and forks, by exe name → their folder under %APPDATA%.</summary>
    static readonly Dictionary<string, string> Editors = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Code.exe"] = "Code",
        ["Code - Insiders.exe"] = "Code - Insiders",
        ["VSCodium.exe"] = "VSCodium",
        ["Cursor.exe"] = "Cursor",
    };

    public Reopen? Capture(WindowInfo w)
    {
        var exe = Path.GetFileName(w.ExePath ?? "");
        try
        {
            if (Editors.TryGetValue(exe, out var data)) return EditorRecipe(w.Title, data);
            if (exe.Equals("explorer.exe", StringComparison.OrdinalIgnoreCase) && w.ClassName == "CabinetWClass")
                return ExplorerPath(w.Hwnd) is { } path ? new Reopen { Folder = path } : null;
        }
        catch (Exception e) { Log.Write($"sleep: reading {exe} window: {e.Message}"); }
        return null;
    }

    /// <summary>The folder (or .code-workspace file) of a VS Code window, from its title
    /// ("file - Folder - Visual Studio Code") and the folders VS Code has open. Null for a
    /// window with unsaved changes ("●" in the title), an empty window or one we can't place.</summary>
    static Reopen? EditorRecipe(string title, string data)
    {
        if (title.StartsWith('●') || title.Contains(" ● ")) return null;
        var parts = title.Split(" - ");
        if (parts.Length < 2) return null;
        var root = parts[^2].Trim();
        if (root.EndsWith('●')) return null;
        var workspace = root.EndsWith(" (Workspace)") ? root[..^" (Workspace)".Length] : null;
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        foreach (var path in OpenFolders(Path.Combine(appData, data)))
        {
            var name = Path.GetFileName(path.TrimEnd('\\'));
            if (workspace is not null && path.EndsWith(".code-workspace", StringComparison.OrdinalIgnoreCase)
                && Path.GetFileNameWithoutExtension(path).Equals(workspace, StringComparison.OrdinalIgnoreCase))
                return new Reopen { Document = path };
            if (workspace is null && name.Equals(root, StringComparison.OrdinalIgnoreCase) && Directory.Exists(path))
                return new Reopen { Folder = path };
        }
        return null;
    }

    /// <summary>Folders and workspace files VS Code has open: the backup registry it keeps while
    /// running (Backups\workspaces.json), then its saved window state (storage.json).</summary>
    static IEnumerable<string> OpenFolders(string data)
    {
        var found = new List<string>();
        void Add(JsonElement e, string prop)
        {
            if (e.ValueKind == JsonValueKind.Object && e.TryGetProperty(prop, out var v) && v.ValueKind == JsonValueKind.String
                && Uri.TryCreate(v.GetString(), UriKind.Absolute, out var uri) && uri.IsFile)
                found.Add(uri.LocalPath);
        }
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(data, "Backups", "workspaces.json")));
            foreach (var key in new[] { "folders", "folderWorkspaceInfos" })
                if (doc.RootElement.TryGetProperty(key, out var list) && list.ValueKind == JsonValueKind.Array)
                    foreach (var f in list.EnumerateArray()) Add(f, "folderUri");
            foreach (var key in new[] { "workspaces", "rootURIWorkspaces" })
                if (doc.RootElement.TryGetProperty(key, out var list) && list.ValueKind == JsonValueKind.Array)
                    foreach (var f in list.EnumerateArray())
                    {
                        Add(f, "configURIPath");
                        if (f.TryGetProperty("workspace", out var ws)) Add(ws, "configPath");
                    }
        }
        catch (IOException) { }
        catch (JsonException) { }
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(data, "User", "globalStorage", "storage.json")));
            if (doc.RootElement.TryGetProperty("windowsState", out var state))
            {
                var windows = new List<JsonElement>();
                if (state.TryGetProperty("openedWindows", out var opened) && opened.ValueKind == JsonValueKind.Array) windows.AddRange(opened.EnumerateArray());
                if (state.TryGetProperty("lastActiveWindow", out var last)) windows.Add(last);
                foreach (var w in windows)
                {
                    Add(w, "folder");
                    if (w.ValueKind == JsonValueKind.Object && w.TryGetProperty("workspace", out var ws)) Add(ws, "configPath");
                }
            }
        }
        catch (IOException) { }
        catch (JsonException) { }
        return found.Distinct(StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>The folder a File Explorer window shows, from the shell's window list. Null for
    /// a window with several tabs (closing it would lose the others) or a virtual folder.</summary>
    static string? ExplorerPath(long hwnd)
    {
        var type = Type.GetTypeFromProgID("Shell.Application");
        if (type is null) return null;
        dynamic shell = Activator.CreateInstance(type)!;
        try
        {
            var paths = new List<string>();
            foreach (dynamic w in shell.Windows())
            {
                try
                {
                    if ((long)w.HWND != hwnd) continue;
                    string path = w.Document.Folder.Self.Path;
                    paths.Add(path);
                }
                catch (Exception) { /* not a folder window (Internet Explorer leftovers) */ }
            }
            if (paths.Count != 1) return null;
            var p = paths[0];
            return p.StartsWith("::") || Directory.Exists(p) ? p : null;
        }
        finally { Marshal.FinalReleaseComObject(shell); }
    }

    public bool Reopen(AppTab tab)
    {
        if (tab.Reopen is not { } r) return false;
        try
        {
            var exe = AppIds.Locate(tab.ExePath);
            var name = Path.GetFileName(exe ?? tab.ExePath ?? "");
            if (Editors.ContainsKey(name) && exe is not null)
            {
                var target = r.Folder ?? r.Document;
                if (target is null || !(Directory.Exists(target) || File.Exists(target))) return false;
                var info = new ProcessStartInfo(exe) { UseShellExecute = false };
                info.ArgumentList.Add("--new-window");
                info.ArgumentList.Add(target);
                Process.Start(info)?.Dispose();
                return true;
            }
            if (name.Equals("explorer.exe", StringComparison.OrdinalIgnoreCase) && r.Folder is { } folder)
            {
                if (!folder.StartsWith("::") && !Directory.Exists(folder)) return false;
                Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { folder }, UseShellExecute = false })?.Dispose();
                return true;
            }
        }
        catch (Exception e) { Log.Write($"sleep: reopening {tab.DisplayName}: {e.Message}"); }
        return false;
    }
}

/// <summary>Which processes have a sound session playing (Core Audio session enumeration on
/// every active output device).</summary>
static class Audio
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumerator { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, nint activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object result);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2
    {
        [PreserveSig] int GetAudioSessionControl(nint guid, int flags, out nint control);
        [PreserveSig] int GetSimpleAudioVolume(nint guid, int flags, out nint volume);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessions);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, out IAudioSessionControl2 session);
    }

    [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2
    {
        // IAudioSessionControl
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName(out nint name);
        [PreserveSig] int SetDisplayName(nint name, nint context);
        [PreserveSig] int GetIconPath(out nint path);
        [PreserveSig] int SetIconPath(nint path, nint context);
        [PreserveSig] int GetGroupingParam(out Guid group);
        [PreserveSig] int SetGroupingParam(ref Guid group, nint context);
        [PreserveSig] int RegisterAudioSessionNotification(nint client);
        [PreserveSig] int UnregisterAudioSessionNotification(nint client);
        // IAudioSessionControl2
        [PreserveSig] int GetSessionIdentifier(out nint id);
        [PreserveSig] int GetSessionInstanceIdentifier(out nint id);
        [PreserveSig] int GetProcessId(out uint pid);
    }

    const int eRender = 0, DEVICE_STATE_ACTIVE = 1, CLSCTX_ALL = 0x17, AudioSessionStateActive = 1;

    public static HashSet<int> ActivePids()
    {
        var pids = new HashSet<int>();
        try
        {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            if (enumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, out var devices) != 0) return pids;
            devices.GetCount(out var n);
            for (uint i = 0; i < n; i++)
            {
                if (devices.Item(i, out var device) != 0) continue;
                var iid = typeof(IAudioSessionManager2).GUID;
                if (device.Activate(ref iid, CLSCTX_ALL, 0, out var o) != 0 || o is not IAudioSessionManager2 manager) continue;
                if (manager.GetSessionEnumerator(out var sessions) != 0) continue;
                sessions.GetCount(out var count);
                for (var s = 0; s < count; s++)
                {
                    if (sessions.GetSession(s, out var session) != 0) continue;
                    if (session.GetState(out var state) == 0 && state == AudioSessionStateActive
                        && session.GetProcessId(out var pid) == 0 && pid != 0)
                        pids.Add((int)pid);
                }
            }
        }
        catch (Exception e) { Log.Write("sleep: reading sound sessions: " + e.Message); }
        return pids;
    }
}
