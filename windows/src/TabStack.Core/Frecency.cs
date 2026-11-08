namespace TabStack.Core;

/// <summary>
/// Which workspaces the sidebar shows: only a few are kept at hand, the rest stay saved and
/// are reached through search. Every use counts, and its weight halves every few days
/// (the way browsers rank address-bar suggestions). Port of the Mac <c>Frecency</c>.
/// </summary>
public static class Frecency
{
    public const double HalfLife = 3 * 24 * 3600;
    public const int Keep = 60;
    public const int DefaultLimit = 5;
    /// <summary>While you stay in a workspace, another use is counted this often.</summary>
    public const double DwellInterval = 10 * 60;

    public static double Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    public static double Score(Workspace ws, double now) =>
        (ws.Usage ?? []).Sum(t => Math.Pow(0.5, Math.Max(0, now - t) / HalfLife));

    public static void RecordUse(Workspace ws, double now)
    {
        var usage = ws.Usage ?? new List<double>();
        usage.Add(now);
        if (usage.Count > Keep) usage.RemoveRange(0, usage.Count - Keep);
        ws.Usage = usage;
    }

    /// <summary>How well <paramref name="query"/> names a workspace: 0 = no match. Prefix beats
    /// word start beats substring beats letters in order; a tab title match counts a little.</summary>
    public static double Match(string query, Workspace ws)
    {
        var q = query.Trim().ToLowerInvariant();
        if (q.Length == 0) return 1;
        var name = ws.Name.ToLowerInvariant();
        if (name == q) return 10;
        if (name.StartsWith(q, StringComparison.Ordinal)) return 8;
        var words = SplitWords(name);
        if (words.Any(w => w.StartsWith(q, StringComparison.Ordinal))) return 6;
        if (name.Contains(q, StringComparison.Ordinal)) return 5;
        if (SubsequenceGaps(q, name) is int gaps) return Math.Max(1, 4 - gaps * 0.3);
        if (ws.Tabs.Any(t => t.DisplayName.ToLowerInvariant().Contains(q) || t.Name.ToLowerInvariant().Contains(q))) return 1.5;
        return 0;
    }

    static IEnumerable<string> SplitWords(string s)
    {
        var start = -1;
        for (var i = 0; i <= s.Length; i++)
        {
            var alnum = i < s.Length && char.IsLetterOrDigit(s[i]);
            if (alnum && start < 0) start = i;
            else if (!alnum && start >= 0) { yield return s[start..i]; start = -1; }
        }
    }

    /// <summary>Letters of <paramref name="q"/> appear in order in <paramref name="s"/>; returns
    /// how many letters were skipped between them.</summary>
    static int? SubsequenceGaps(string q, string s)
    {
        int gaps = 0, j = 0;
        var started = false;
        foreach (var c in q)
        {
            var found = false;
            while (j < s.Length)
            {
                var x = s[j++];
                if (x == c) { found = true; break; }
                if (started) gaps++;
            }
            if (!found) return null;
            started = true;
        }
        return gaps;
    }

    /// <summary>The workspaces the sidebar shows: current, those shown on other displays and
    /// pinned first, then the highest frecency, up to <paramref name="limit"/>.</summary>
    public static HashSet<Guid> Active(IReadOnlyList<Workspace> workspaces, Guid current,
        IEnumerable<Guid> shownElsewhere, int limit, double now)
    {
        var chosen = new List<Guid> { current };
        foreach (var id in shownElsewhere) if (!chosen.Contains(id)) chosen.Add(id);
        foreach (var ws in workspaces) if (ws.Pinned == true && !chosen.Contains(ws.Id)) chosen.Add(ws.Id);
        var ranked = workspaces.Select((ws, i) => (ws, i))
            .Where(x => !chosen.Contains(x.ws.Id))
            .OrderByDescending(x => Score(x.ws, now)).ThenBy(x => x.i);
        foreach (var (ws, _) in ranked)
        {
            if (chosen.Count >= limit) break;
            chosen.Add(ws.Id);
        }
        return chosen.ToHashSet();
    }

    /// <summary>Search results: with no query, every workspace by frecency; otherwise by how
    /// well the name matches, weighted by frecency.</summary>
    public static List<Workspace> Search(IReadOnlyList<Workspace> workspaces, string query, double now)
    {
        var blank = string.IsNullOrWhiteSpace(query);
        return workspaces.Select((ws, i) => (ws, i, m: Match(query, ws), f: Score(ws, now)))
            .Where(x => x.m > 0)
            .OrderByDescending(x => blank ? x.f : x.m * (1 + Math.Log(1 + x.f)))
            .ThenBy(x => x.i)
            .Select(x => x.ws).ToList();
    }
}
