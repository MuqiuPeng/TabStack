using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace TabStack.App;

/// <summary>One-line text prompt. Returns null when cancelled.</summary>
sealed class InputDialog : Window
{
    readonly TextBox box;

    InputDialog(string title, string prompt, string initial)
    {
        Title = title;
        SizeToContent = SizeToContent.WidthAndHeight;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        box = new TextBox { Text = initial, MinWidth = 280, Margin = new Thickness(0, 6, 0, 12) };
        var ok = new Button { Content = "确定", IsDefault = true, MinWidth = 72, Margin = new Thickness(0, 0, 8, 0) };
        ok.Click += (_, _) => DialogResult = true;
        var cancel = new Button { Content = "取消", IsCancel = true, MinWidth = 72 };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(ok);
        buttons.Children.Add(cancel);
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(new TextBlock { Text = prompt });
        panel.Children.Add(box);
        panel.Children.Add(buttons);
        Content = panel;
        Loaded += (_, _) => { Activate(); box.SelectAll(); Keyboard.Focus(box); };
    }

    public static string? Ask(string title, string prompt, string initial)
    {
        var d = new InputDialog(title, prompt, initial);
        return d.ShowDialog() == true ? d.box.Text : null;
    }
}
