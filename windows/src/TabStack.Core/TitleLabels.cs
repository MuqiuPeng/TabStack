using System.Text.RegularExpressions;

namespace TabStack.Core;

/// <summary>Short labels for the sidebar when a workspace holds several windows of one app:
/// the window title minus what says nothing about the window (browser and profile name,
/// what Chrome appends about the tab, Explorer's and Edge's "and N more", unread counts).
/// The Mac version can also shorten long titles with the on-device model; Windows has none.</summary>
public static partial class TitleLabels
{
    static readonly Regex[] Noise =
    [
        // Browser name, with Edge's profile before it ("… - 个人 - Microsoft​ Edge").
        Browser(),
        // What Chrome appends about the tab, not the page.
        ChromeNotes(),
        // "… 和另外 3 个页面", "… and 3 more pages", Explorer's "… 和 1 个其他选项卡".
        MoreTabs(),
        Explorer(),
        Unread(),
    ];

    public static string Clean(string title)
    {
        var t = title;
        foreach (var r in Noise) t = r.Replace(t, "");
        t = t.Trim();
        return t.Length > 0 ? t : title.Trim();
    }

    /// <summary>Display width: a CJK character counts as two letters.</summary>
    public static int Width(string s) => s.Sum(c => IsWide(c) ? 2 : 1);

    static bool IsWide(char c) =>
        c is >= '⺀' and <= '鿿' or >= '가' and <= '힯' or >= '豈' and <= '﫿' or >= '＀' and <= '￯';

    [GeneratedRegex(@"( [-–—] (个人|工作|Personal|Work|配置文件 \d+|Profile \d+))? [-–—] (Google Chrome|Microsoft​? ?Edge|Brave|Mozilla Firefox|Firefox|Opera|Vivaldi)$")]
    private static partial Regex Browser();

    [GeneratedRegex(@" - (High memory usage - [\d.]+ [KMG]B|Audio playing|Muted|Camera recording|Microphone recording|Camera and microphone recording|Bluetooth device connected|Pinned|内存使用量(较|过)?高 - [\d.]+ [KMG]B|正在播放音频|音频播放中|已静音|正在使用摄像头|正在使用麦克风|正在使用摄像头和麦克风|已连接蓝牙设备|已固定)")]
    private static partial Regex ChromeNotes();

    [GeneratedRegex(@" (和另外 \d+ 个页面|和 \d+ 个其他选项卡|and \d+ more (pages?|tabs?))")]
    private static partial Regex MoreTabs();

    [GeneratedRegex(@" [-–—] (文件资源管理器|File Explorer)$")]
    private static partial Regex Explorer();

    [GeneratedRegex(@"^\(\d+\) ")]
    private static partial Regex Unread();
}
