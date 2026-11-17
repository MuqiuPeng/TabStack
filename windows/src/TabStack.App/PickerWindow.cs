using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using TabStack.Core;

namespace TabStack.App;

/// <summary>One row of a picker: what it shows and what Enter does.</summary>
sealed record PickerItem(string Text, string? Detail, ImageSource? Icon, Action Run, FrameworkElement? Badge = null);

/// <summary>A Spotlight-style box (Mac ⌃⌥F / ⌃⌥A): a search line and the matching rows, near
/// the top of the focused display. ↑↓ choose, Enter runs, Esc or clicking elsewhere closes.</summary>
sealed class PickerWindow : Window
{
    static readonly Brush Back = Frozen(Color.FromRgb(0x26, 0x27, 0x2B));
    static readonly Brush Line = Frozen(Color.FromRgb(0x3A, 0x3B, 0x40));
    static readonly Brush Fore = Frozen(Color.FromRgb(0xE6, 0xE6, 0xE6));
    static readonly Brush Dim = Frozen(Color.FromRgb(0x9A, 0x9B, 0xA0));
    static readonly Brush Pick = Frozen(Color.FromArgb(0x40, 0x4F, 0x7D, 0xF3));

    readonly TextBox box;
    readonly StackPanel rows = new();
    readonly ScrollViewer scroll;
    readonly Func<string, IReadOnlyList<PickerItem>> source;
    List<PickerItem> items = new();
    int index;
    bool closing;

    public PickerWindow(string placeholder, Func<string, IReadOnlyList<PickerItem>> source, MonitorInfo? display)
    {
        this.source = source;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Width = 600;
        SizeToContent = SizeToContent.Height;
        Background = Back;
        BorderBrush = Line;
        BorderThickness = new Thickness(1);
        Title = "TabStack";

        var hint = new TextBlock { Text = placeholder, Foreground = Dim, FontSize = 18, Margin = new Thickness(16, 12, 16, 12), IsHitTestVisible = false };
        box = new TextBox
        {
            FontSize = 18, Foreground = Fore, Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            CaretBrush = Fore, Margin = new Thickness(12, 12, 12, 12),
        };
        box.TextChanged += (_, _) => { hint.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; Refill(); };
        var top = new Grid();
        top.Children.Add(hint);
        top.Children.Add(box);

        scroll = new ScrollViewer { Content = rows, MaxHeight = 440, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var root = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);
        var sep = new Border { Height = 1, Background = Line };
        DockPanel.SetDock(sep, Dock.Top);
        root.Children.Add(sep);
        root.Children.Add(scroll);
        Content = root;

        if (display is not null)
        {
            var k = 96.0 / Math.Max(display.Dpi, 96);
            Left = display.WorkArea.X * k + (display.WorkArea.W * k - Width) / 2;
            Top = display.WorkArea.Y * k + display.WorkArea.H * k * 0.18;
        }
        else WindowStartupLocation = WindowStartupLocation.CenterScreen;

        PreviewKeyDown += OnKey;
        Deactivated += (_, _) => Dismiss();
        Loaded += (_, _) => { Activate(); Keyboard.Focus(box); };
        Refill();
    }

    void Dismiss()
    {
        if (closing) return;
        closing = true;
        Close();
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Escape: Dismiss(); break;
            case Key.Down: Move(1); break;
            case Key.Up: Move(-1); break;
            case Key.Enter: RunSelected(); break;
            default: return;
        }
        e.Handled = true;
    }

    void Move(int d)
    {
        if (items.Count == 0) return;
        index = (index + d + items.Count) % items.Count;
        Paint();
    }

    void RunSelected()
    {
        if (items.ElementAtOrDefault(index) is not { } item) return;
        Dismiss();
        // Run after the box is gone, so the window it shows can take the focus.
        Dispatcher.BeginInvoke(item.Run, System.Windows.Threading.DispatcherPriority.Background);
    }

    void Refill()
    {
        items = source(box.Text.Trim()).ToList();
        index = 0;
        Paint();
    }

    void Paint()
    {
        rows.Children.Clear();
        if (items.Count == 0)
        {
            rows.Children.Add(new TextBlock { Text = "No matches", Foreground = Dim, Margin = new Thickness(16, 10, 16, 12) });
            return;
        }
        for (var i = 0; i < items.Count; i++)
        {
            var item = items[i];
            var row = new DockPanel { Margin = new Thickness(10, 6, 10, 6) };
            FrameworkElement icon = item.Badge ?? (item.Icon is { } src
                ? new Image { Source = src, Width = 24, Height = 24 }
                : new Border { Width = 24, Height = 24 });
            icon.Margin = new Thickness(0, 0, 10, 0);
            icon.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(icon, Dock.Left);
            row.Children.Add(icon);
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock { Text = item.Text, Foreground = Fore, FontSize = 14, TextTrimming = TextTrimming.CharacterEllipsis });
            if (!string.IsNullOrEmpty(item.Detail))
                text.Children.Add(new TextBlock { Text = item.Detail, Foreground = Dim, FontSize = 11.5, TextTrimming = TextTrimming.CharacterEllipsis });
            row.Children.Add(text);
            var at = i;
            var cell = new Border
            {
                Child = row, Background = i == index ? Pick : Brushes.Transparent, Cursor = Cursors.Hand,
                CornerRadius = new CornerRadius(4), Margin = new Thickness(6, 1, 6, 1),
            };
            cell.MouseLeftButtonUp += (_, _) => { index = at; RunSelected(); };
            rows.Children.Add(cell);
            if (i == index) cell.Loaded += (_, _) => cell.BringIntoView();
        }
    }

    static Brush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }
}
