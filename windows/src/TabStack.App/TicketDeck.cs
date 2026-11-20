using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using TabStack.Core;

namespace TabStack.App;

/// <summary>The `ticketdeck` CLI (TicketDeck: tickets as markdown in each repo's .tickets/).
/// ⌃⌥T reads and changes tickets only through it, so there is one implementation of the
/// format. <c>ticketdeck setup</c> writes where it lives to ~/.ticketdeck/cli.json.</summary>
static class TicketDeck
{
    sealed record Location(string Node, string Cli);

    public static string Home => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ticketdeck");
    public static string ReportsDir => Path.Combine(Home, "reports");

    public const string NotSetUp = "TicketDeck not found. Run `ticketdeck setup` in the TicketDeck folder, then try again.";

    static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };

    static Location? Find()
    {
        try
        {
            var loc = JsonSerializer.Deserialize<Location>(File.ReadAllText(Path.Combine(Home, "cli.json")), Json);
            return loc is not null && File.Exists(loc.Node) && File.Exists(loc.Cli) ? loc : null;
        }
        catch { return null; }
    }

    /// <summary>Runs the CLI off the UI thread. Error is the CLI's message on failure.</summary>
    public static Task<(bool Ok, string Output, string Error)> Run(IEnumerable<string> args, string? dir = null) => Task.Run(() =>
    {
        if (Find() is not { } loc) return (false, "", NotSetUp);
        try
        {
            var info = new ProcessStartInfo(loc.Node)
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            };
            if (dir is not null && Directory.Exists(dir)) info.WorkingDirectory = dir;
            info.ArgumentList.Add(loc.Cli);
            foreach (var a in args) info.ArgumentList.Add(a);
            using var p = Process.Start(info)!;
            var err = p.StandardError.ReadToEndAsync();
            var output = p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            return (p.ExitCode == 0, output, err.Result.Trim());
        }
        catch (Exception e) { return (false, "", e.Message); }
    });

    sealed record StateJson(List<TicketProject> Projects);

    /// <summary>Every project's tickets (done ones until archived); the raw JSON too, to tell
    /// whether anything changed.</summary>
    public static async Task<(List<TicketProject>? Projects, string Raw, string? Error)> State()
    {
        var (ok, output, error) = await Run(["state"]);
        if (!ok) return (null, "", error.Length > 0 ? error : "ticketdeck state failed");
        try
        {
            var projects = JsonSerializer.Deserialize<StateJson>(output, Json)?.Projects ?? [];
            foreach (var p in projects)
                foreach (var t in p.Tickets) { t.ProjectPath = p.Path; t.ProjectName = p.Name; }
            return (projects, output, null);
        }
        catch (Exception e) { return (null, "", e.Message); }
    }

    public static T? Read<T>(string file) where T : class
    {
        try { return JsonSerializer.Deserialize<T>(File.ReadAllText(file), Json); }
        catch { return null; }
    }
}

sealed class TicketProject
{
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
    public List<TicketItem> Tickets { get; set; } = [];
}

sealed class TicketItem
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public string Status { get; set; } = "";
    public string Priority { get; set; } = "";
    public string Type { get; set; } = "";
    public List<string> Labels { get; set; } = [];
    public string Updated { get; set; } = "";
    public string? Session { get; set; }
    [JsonPropertyName("depends_on")] public List<string> DependsOn { get; set; } = [];
    public string Body { get; set; } = "";
    [JsonIgnore] public string ProjectPath { get; set; } = "";
    [JsonIgnore] public string ProjectName { get; set; } = "";

    /// <summary>Unique across projects (ids restart at T-0001 in each).</summary>
    public string Key => ProjectPath + "#" + Id;

    public bool HasClaudeSession => Session?.StartsWith("local_") == true;

    /// <summary>The body up to the log, and the log lines (newest last). "## 日志" since tickets
    /// are written in Chinese; "## Log" in older ones.</summary>
    public (string Description, List<string> Log) Parts
    {
        get
        {
            var body = Body.Replace("\r\n", "\n");
            foreach (var h in new[] { "## 日志", "## Log" })
            {
                var at = body.StartsWith(h + "\n") ? 0 : body.IndexOf("\n" + h + "\n", StringComparison.Ordinal) is var i and >= 0 ? i + 1 : -1;
                if (at < 0) continue;
                var log = body[(at + h.Length + 1)..].Split('\n', StringSplitOptions.RemoveEmptyEntries)
                    .Select(l => l.StartsWith("- ") ? l[2..] : l).ToList();
                return (body[..at], log);
            }
            return (body, []);
        }
    }

    /// <summary>Whether a line is a checklist item, and if so whether ticked and its text.</summary>
    public static (bool Done, string Text)? Check(string line)
    {
        var s = line.Trim();
        if (s.Length < 5 || !(s.StartsWith("- [") || s.StartsWith("* [") || s.StartsWith("+ [")) || s[4] != ']') return null;
        if (s[3] is not (' ' or 'x' or 'X')) return null;
        return (s[3] != ' ', s[5..].Trim());
    }
}

/// <summary>TicketDeck's daily report (~/.ticketdeck/reports/&lt;date&gt;.json): 今日计划 and 提议执行.</summary>
sealed class DailyReport
{
    public sealed class TotalsJson { public int Open { get; set; } public int Review { get; set; } public int Doing { get; set; } public int Todo { get; set; } public int Decisions { get; set; } public int Done { get; set; } public int Stale { get; set; } public int Projects { get; set; } }
    public sealed class Item { public string Project { get; set; } = ""; public string Root { get; set; } = ""; public string Id { get; set; } = ""; public string Title { get; set; } = ""; public string Priority { get; set; } = ""; public string? Session { get; set; } public bool? Stale { get; set; } }
    public sealed class Activity { public string Project { get; set; } = ""; public string Root { get; set; } = ""; public int Created { get; set; } public int Done { get; set; } public int Updated { get; set; } }
    public sealed class Leftover { public string Project { get; set; } = ""; public string Task { get; set; } = ""; public string? Session { get; set; } }
    public sealed class Proposal { public string Id { get; set; } = ""; public string Project { get; set; } = ""; public string Root { get; set; } = ""; public string Title { get; set; } = ""; public string Prompt { get; set; } = ""; public string? Why { get; set; } public List<string>? Tickets { get; set; } public string? Status { get; set; } }
    public sealed class Focus { public string Project { get; set; } = ""; public string Root { get; set; } = ""; public string Id { get; set; } = ""; public string Title { get; set; } = ""; public string Priority { get; set; } = ""; public string Kind { get; set; } = ""; public string? Session { get; set; } public int IdleDays { get; set; } public string? Reason { get; set; } }

    public string Date { get; set; } = "";
    public string GeneratedAt { get; set; } = "";
    public TotalsJson Totals { get; set; } = new();
    public string? Summary { get; set; }
    public List<Item> Review { get; set; } = [];
    public List<Item> Decisions { get; set; } = [];
    public List<Item> Doing { get; set; } = [];
    [JsonPropertyName("activity")] public List<Activity> ActivityList { get; set; } = [];
    public List<Leftover>? Leftovers { get; set; }
    public List<Proposal>? Proposals { get; set; }
    [JsonPropertyName("focus")] public List<Focus>? FocusList { get; set; }

    public static string Today => DateTime.Now.ToString("yyyy-MM-dd");

    public string StatusLine
    {
        get
        {
            var parts = new[]
            {
                Totals.Done > 0 ? $"昨日完成 {Totals.Done} 项" : null,
                Totals.Review > 0 ? $"{Totals.Review} 项待验收" : null,
                Totals.Stale > 0 ? $"{Totals.Stale} 项停滞" : null,
            }.OfType<string>().ToList();
            return parts.Count == 0 ? $"{Totals.Open} 项任务进行中" : string.Join(" · ", parts);
        }
    }

    public string DayTitle
    {
        get
        {
            if (!DateTime.TryParseExact(Date, "yyyy-MM-dd", null, System.Globalization.DateTimeStyles.None, out var d)) return Date;
            var week = new[] { "周日", "周一", "周二", "周三", "周四", "周五", "周六" }[(int)d.DayOfWeek];
            return $"{d.Month} 月 {d.Day} 日 · {week}";
        }
    }

    /// <summary>Report dates on disk, newest first.</summary>
    public static List<string> Dates()
    {
        try
        {
            return Directory.EnumerateFiles(TicketDeck.ReportsDir, "*.json")
                .Select(Path.GetFileName).OfType<string>()
                .Where(n => System.Text.RegularExpressions.Regex.IsMatch(n, @"^\d{4}-\d{2}-\d{2}\.json$"))
                .Select(n => n[..10]).OrderByDescending(d => d, StringComparer.Ordinal).ToList();
        }
        catch { return []; }
    }

    public static DailyReport? Load(string date) => TicketDeck.Read<DailyReport>(Path.Combine(TicketDeck.ReportsDir, date + ".json"));
}

/// <summary>TicketDeck's background 提议执行 run (~/.ticketdeck/reports/&lt;date&gt;.propose.json).</summary>
sealed class ProposeJob
{
    public string State { get; set; } = "";
    public int? Pid { get; set; }
    public string? Error { get; set; }

    /// <summary>Running, and its process still there (a crashed run leaves "running" behind).</summary>
    public bool Running
    {
        get
        {
            if (State != "running" || Pid is not { } pid) return false;
            try { using var p = Process.GetProcessById(pid); return !p.HasExited; }
            catch { return false; }
        }
    }

    public static ProposeJob? Load(string date) => TicketDeck.Read<ProposeJob>(Path.Combine(TicketDeck.ReportsDir, date + ".propose.json"));
}

/// <summary>Claude desktop's Code sessions, through its own deep links (registered for
/// claude://). Leans on Claude's link format, so failures are quiet.</summary>
static class ClaudeLinks
{
    public static bool IsClaude(AppTab t) =>
        t.AppID.StartsWith("Claude_", StringComparison.OrdinalIgnoreCase) && t.AppID.EndsWith("!Claude", StringComparison.OrdinalIgnoreCase);

    /// <summary>Shows a session in Claude.</summary>
    public static void Open(string session)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(session, "^local_[A-Za-z0-9-]{1,64}$")) return;
        Start($"claude://code/continue?session={session}&source=url_external");
    }

    /// <summary>A new Code session in <paramref name="folder"/> with <paramref name="prompt"/>
    /// in its input box; the user sends it (Claude never sends a prompt from a link).</summary>
    public static void NewSession(string prompt, string folder)
    {
        string Url(string p) => "claude://code/new?q=" + Uri.EscapeDataString(p)
            + "&folder=" + Uri.EscapeDataString(folder) + "&source=url_external";
        // Command lines end at 32K characters; percent-encoded Chinese takes nine per character.
        var text = prompt.Length > 14_000 ? prompt[..14_000] : prompt;
        while (Url(text).Length > 30_000) text = text[..(text.Length * 3 / 4)];
        Start(Url(text));
    }

    static void Start(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception e) { Log.Write("claude link: " + e.Message); }
    }
}
