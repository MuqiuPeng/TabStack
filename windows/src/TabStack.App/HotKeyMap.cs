using System.Windows.Input;
using TabStack.Core;
using TabStack.Platform.Windows;

namespace TabStack.App;

/// <summary>Hotkey actions, their default chords and chord parsing.</summary>
static class HotKeyMap
{
    public sealed record Action(string Id, string Label, string Default);

    /// <summary>Mac ⌃⌥ → Ctrl+Alt. Mac ⌥⌘ (tabs) → Ctrl+Alt+Shift: Win+Alt+digit is the taskbar
    /// jump list on Windows, and Ctrl+Alt+A is a common screenshot key (QQ/TIM/WeChat).</summary>
    public static readonly IReadOnlyList<Action> All = BuildAll();

    static List<Action> BuildAll()
    {
        var list = new List<Action>();
        for (var i = 1; i <= 9; i++) list.Add(new($"workspace{i}", $"切到第 {i} 个工作区", $"Ctrl+Alt+{i}"));
        for (var i = 1; i <= 9; i++) list.Add(new($"tab{i}", $"切到第 {i} 个标签", $"Ctrl+Alt+Shift+{i}"));
        list.Add(new("prevTab", "上一个标签", "Ctrl+Alt+Up"));
        list.Add(new("nextTab", "下一个标签", "Ctrl+Alt+Down"));
        list.Add(new("prevWorkspace", "上一个工作区", "Ctrl+Alt+Left"));
        list.Add(new("nextWorkspace", "下一个工作区", "Ctrl+Alt+Right"));
        list.Add(new("addWindow", "把当前窗口加入工作区", "Ctrl+Alt+Shift+A"));
        list.Add(new("toggleTile", "切换平铺模式", "Ctrl+Alt+T"));
        return list;
    }

    public static string ChordFor(Settings s, Action a) =>
        s.HotKeys.TryGetValue(a.Id, out var c) ? c : a.Default;

    /// <summary>"Ctrl+Alt+Left" → modifiers and virtual key; null when empty or invalid.</summary>
    public static (Modifiers mods, int vk)? Parse(string chord)
    {
        if (string.IsNullOrWhiteSpace(chord)) return null;
        Modifiers mods = 0;
        Key key = Key.None;
        foreach (var part in chord.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            switch (part.ToLowerInvariant())
            {
                case "ctrl": case "control": mods |= Modifiers.Control; break;
                case "alt": mods |= Modifiers.Alt; break;
                case "shift": mods |= Modifiers.Shift; break;
                case "win": mods |= Modifiers.Win; break;
                default:
                    var name = part.Length == 1 && char.IsDigit(part[0]) ? "D" + part : part;
                    if (!Enum.TryParse(name, true, out key)) return null;
                    break;
            }
        }
        if (key == Key.None || mods == 0) return null;
        return (mods, KeyInterop.VirtualKeyFromKey(key));
    }

    /// <summary>Formats a key press for the settings window, or null for a lone modifier.</summary>
    public static string? Format(ModifierKeys mods, Key key, bool win)
    {
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift
            or Key.LWin or Key.RWin or Key.System or Key.None) return null;
        var parts = new List<string>();
        if (mods.HasFlag(ModifierKeys.Control)) parts.Add("Ctrl");
        if (mods.HasFlag(ModifierKeys.Alt)) parts.Add("Alt");
        if (mods.HasFlag(ModifierKeys.Shift)) parts.Add("Shift");
        if (win || mods.HasFlag(ModifierKeys.Windows)) parts.Add("Win");
        if (parts.Count == 0) return null;
        var name = key is >= Key.D0 and <= Key.D9 ? ((int)(key - Key.D0)).ToString() : key.ToString();
        parts.Add(name);
        return string.Join("+", parts);
    }
}
