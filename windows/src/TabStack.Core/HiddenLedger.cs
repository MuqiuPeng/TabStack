using System.Text.Json;

namespace TabStack.Core;

/// <summary>
/// Every window TabStack has hidden, written to disk <em>before</em> it is hidden, so that if
/// TabStack dies the windows can be shown again (at the next start, or by the watchdog).
/// A window counts only while its process is the same one (pid + start time).
/// </summary>
public sealed class HiddenLedger
{
    public sealed record Entry(long Hwnd, int Pid, long StartTime);

    readonly string path;
    readonly object gate = new();
    List<Entry> entries;

    public HiddenLedger(string path)
    {
        this.path = path;
        entries = Read(path);
    }

    public static string DefaultPath => System.IO.Path.Combine(Store.DefaultDirectory, "hidden.json");

    public IReadOnlyList<Entry> Entries { get { lock (gate) return entries.ToList(); } }

    public bool Contains(long hwnd) { lock (gate) return entries.Exists(e => e.Hwnd == hwnd); }

    public void Add(long hwnd, ProcessStamp stamp)
    {
        lock (gate)
        {
            entries.RemoveAll(e => e.Hwnd == hwnd);
            entries.Add(new Entry(hwnd, stamp.Pid, stamp.StartTime));
            Write();
        }
    }

    public void Remove(long hwnd)
    {
        lock (gate)
        {
            if (entries.RemoveAll(e => e.Hwnd == hwnd) > 0) Write();
        }
    }

    /// <summary>Forgets windows that were closed (or whose process was replaced) while hidden.</summary>
    public void Prune(IWindowPlatform platform)
    {
        lock (gate)
        {
            var removed = entries.RemoveAll(e => platform.Stamp(e.Hwnd) is not { } s || s.Pid != e.Pid || s.StartTime != e.StartTime);
            if (removed > 0) Write();
        }
    }

    /// <summary>Shows every window still alive in the same process; empties the ledger.
    /// Returns how many were shown.</summary>
    public int RestoreAll(IWindowPlatform platform) => RestoreFrom(path, platform, this);

    /// <summary>Used by the watchdog, which reads the file the dead process left behind.</summary>
    public static int RestoreFrom(string path, IWindowPlatform platform, HiddenLedger? live = null)
    {
        var list = live?.Entries ?? Read(path);
        var shown = 0;
        foreach (var e in list)
        {
            if (platform.Stamp(e.Hwnd) is { } s && s.Pid == e.Pid && s.StartTime == e.StartTime)
            {
                platform.Show(e.Hwnd);
                shown++;
            }
        }
        if (live is not null) lock (live.gate) { live.entries.Clear(); live.Write(); }
        else if (File.Exists(path)) Store.AtomicWrite(path, "[]");
        return shown;
    }

    void Write() => Store.AtomicWrite(path, JsonSerializer.Serialize(entries, Store.Json));

    static List<Entry> Read(string path)
    {
        try
        {
            if (File.Exists(path))
                return JsonSerializer.Deserialize<List<Entry>>(File.ReadAllText(path), Store.Json) ?? new();
        }
        catch (Exception e) when (e is JsonException or IOException) { }
        return new();
    }
}
